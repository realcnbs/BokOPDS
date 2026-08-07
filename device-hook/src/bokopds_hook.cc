#include <NickelHook.h>

#include <QApplication>
#include <QDir>
#include <QFile>
#include <QHBoxLayout>
#include <QProcess>
#include <QPushButton>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QWidget>

#include <cerrno>
#include <signal.h>
#include <sys/types.h>

#include <cstddef>
#include <cstdlib>
#include <new>

namespace {

constexpr const char* application_directory = "/mnt/onboard/.adds/bokopds";
constexpr const char* launcher_path = "/mnt/onboard/.adds/bokopds/launch.sh";
constexpr const char* library_refresh_marker = "/mnt/onboard/.adds/bokopds/library-refresh.pending";
constexpr const char* runtime_lock_directory = "/tmp/bokopds-running";

typedef QWidget MainNavButton;
typedef QWidget MainNavView;
typedef void PlugWorkflowManager;

#include "../generated/compatibility_profiles.h"

BokOPDSCompatibilityTarget* active_target = nullptr;

struct nh_info BokOPDSInfo = {
    .name = "BokOPDS",
    .desc = "Direct OPDS catalog launcher.",
    .uninstall_flag = "/mnt/onboard/.adds/bokopds/uninstall",
    .uninstall_xflag = nullptr,
    .failsafe_delay = 3,
};

void refresh_library_if_pending();

bool read_device_identity(QString* firmware, QString* hardware_id) {
    QFile version_file(QStringLiteral("/mnt/onboard/.kobo/version"));
    if (!version_file.open(QIODevice::ReadOnly)) {
        nh_log("compatibility check could not read the device version file");
        return false;
    }
    const QString version = QString::fromLatin1(version_file.readLine()).trimmed();
    const QStringList fields = version.split(QLatin1Char(','));
    if (fields.size() < 4) {
        nh_log("compatibility check found a malformed device version file");
        return false;
    }
    *firmware = fields.at(2).trimmed();
    QString identifier = fields.at(fields.size() - 1).trimmed();
    identifier = identifier.section(QLatin1Char('-'), -1);
    while (identifier.size() > 1 && identifier.startsWith(QLatin1Char('0'))) {
        identifier.remove(0, 1);
    }
    if (firmware->isEmpty() || identifier.isEmpty()) {
        nh_log("compatibility check could not determine firmware or hardware id");
        return false;
    }
    *hardware_id = identifier;
    return true;
}

BokOPDSCompatibilityTarget* select_compatibility_target(const QString& firmware,
                                                         const QString& hardware_id) {
    for (std::size_t index = 0; index < BokOPDSTargetCount; ++index) {
        BokOPDSCompatibilityTarget* target = &BokOPDSTargets[index];
        if (firmware != QString::fromLatin1(target->firmware)) {
            continue;
        }
        for (std::size_t hardware_index = 0;
             hardware_index < target->hardware_id_count; ++hardware_index) {
            if (hardware_id == QString::fromLatin1(target->hardware_ids[hardware_index])) {
                return target;
            }
        }
    }
    return nullptr;
}

bool target_has_required_symbols(const BokOPDSCompatibilityTarget* target) {
    const BokOPDSAbiProfile* abi = target->abi;
    return abi != nullptr && abi->main_nav_construct != nullptr &&
           abi->main_nav_set_pixmap != nullptr &&
           abi->main_nav_set_active_pixmap != nullptr &&
           abi->main_nav_set_text != nullptr;
}

bool application_is_running() {
    QDir lock(QString::fromLatin1(runtime_lock_directory));
    if (!lock.exists()) {
        return false;
    }
    QFile pid_file(lock.filePath(QStringLiteral("pid")));
    if (pid_file.open(QIODevice::ReadOnly)) {
        bool ok = false;
        const qint64 pid = QString::fromLatin1(pid_file.readAll()).trimmed().toLongLong(&ok);
        if (ok && pid > 1 && (::kill(static_cast<pid_t>(pid), 0) == 0 || errno == EPERM)) {
            return true;
        }
    }
    // A hard-killed supervisor or runtime may leave the directory behind.
    // Only the PID file is ever stored here, so this cleanup is narrowly scoped.
    lock.removeRecursively();
    return false;
}

bool launch_application() {
    qint64 process_id = 0;
    if (active_target == nullptr) {
        nh_log("refused to launch without an active compatibility target");
        return false;
    }
    const QString command =
        QStringLiteral("export BOKOPDS_COMPATIBILITY_TARGET='") +
        QString::fromLatin1(active_target->id) +
        QStringLiteral("' BOKOPDS_COMPATIBILITY_STATE='") +
        QString::fromLatin1(active_target->state) +
        QStringLiteral("'; exec \"") + QString::fromLatin1(launcher_path) +
        QStringLiteral("\"");
    const bool started = QProcess::startDetached(QStringLiteral("/bin/sh"),
                                   QStringList() << QStringLiteral("-c")
                                                 << command,
                                   QString::fromLatin1(application_directory), &process_id);
    if (started && active_target->abi->library_refresh_shared_instance != nullptr &&
        active_target->abi->library_refresh_sync != nullptr) {
        // Watch only after a launch. The stock process should not wake and stat
        // the FAT filesystem forever when BokOPDS has never been opened.
        QTimer* refresh_timer = new QTimer(QApplication::instance());
        refresh_timer->setInterval(1500);
        int* attempts = new int(0);
        QObject::connect(refresh_timer, &QTimer::timeout, [refresh_timer, attempts] {
            ++*attempts;
            const bool app_running = application_is_running();
            const bool refresh_pending = QFile::exists(QString::fromLatin1(library_refresh_marker));
            if (refresh_pending && !app_running) {
                refresh_library_if_pending();
            }
            if ((!app_running && !refresh_pending) || *attempts >= 28800) {
                refresh_timer->stop();
                refresh_timer->deleteLater();
                delete attempts;
            }
        });
        refresh_timer->start();
    }
    return started;
}

bool uninstall_application() {
    // NickelHook removes the uninstall marker before invoking this callback.
    return QDir(QStringLiteral("/mnt/onboard/.adds/bokopds")).removeRecursively();
}

void refresh_library_if_pending() {
    if (!QFile::exists(QString::fromLatin1(library_refresh_marker))) {
        return;
    }
    // Never ask the built-in library to scan while a download may still be
    // writing. The launcher removes this lock only after the app has exited.
    if (application_is_running()) {
        return;
    }
    if (active_target == nullptr || active_target->abi == nullptr ||
        active_target->abi->library_refresh_shared_instance == nullptr ||
        active_target->abi->library_refresh_sync == nullptr) {
        nh_log("library refresh is pending but the required firmware symbols are unavailable");
        return;
    }
    PlugWorkflowManager* workflow = active_target->abi->library_refresh_shared_instance();
    if (workflow == nullptr) {
        nh_log("library refresh is pending but the workflow manager is unavailable");
        return;
    }
    active_target->abi->library_refresh_sync(workflow);
    if (!QFile::remove(QString::fromLatin1(library_refresh_marker))) {
        nh_log("library refresh was requested but the pending marker could not be removed");
        return;
    }
    nh_log("requested native library refresh for newly downloaded publications");
}

bool add_navigation_button(MainNavView* view) {
    if (active_target == nullptr || !target_has_required_symbols(active_target)) {
        return false;
    }
    if (view->findChild<QWidget*>(QStringLiteral("bokopdsButton")) != nullptr) {
        return true;
    }
    QHBoxLayout* layout = view->findChild<QHBoxLayout*>();
    if (layout == nullptr) {
        return false;
    }

    // MainNavButton is a private firmware class. The selected target carries
    // the storage size checked for its exact firmware ABI. Use the C++
    // allocator so QObject/Qt destruction calls the matching operator delete.
    BokOPDSAbiProfile* abi = active_target->abi;
    MainNavButton* button = reinterpret_cast<MainNavButton*>(
        ::operator new(abi->widget_storage_bytes, std::nothrow));
    if (button == nullptr) {
        nh_log("could not allocate main navigation button");
        return false;
    }
    abi->main_nav_construct(button, view->parentWidget());
    abi->main_nav_set_text(button, QStringLiteral("BokOPDS"));
    abi->main_nav_set_pixmap(button, QStringLiteral("/mnt/onboard/.adds/bokopds/menu-book.png"));
    abi->main_nav_set_active_pixmap(
        button, QStringLiteral("/mnt/onboard/.adds/bokopds/menu-book-active.png"));
    button->setObjectName(QStringLiteral("bokopdsButton"));

    QPushButton* adapter = new QPushButton(view);
    adapter->setVisible(false);
    if (!QWidget::connect(button, SIGNAL(tapped()), adapter, SIGNAL(pressed()))) {
        nh_log("could not connect main navigation tap signal");
        button->deleteLater();
        adapter->deleteLater();
        return false;
    }
    QObject::connect(adapter, &QPushButton::pressed, [] {
        if (!launch_application()) {
            nh_log("could not launch BokOPDS");
        }
    });

    layout->addWidget(button, 1);
    view->ensurePolished();
    if (QFile::exists(QString::fromLatin1(library_refresh_marker))) {
        QTimer* timer = new QTimer(view);
        timer->setSingleShot(true);
        QObject::connect(timer, &QTimer::timeout, [] { refresh_library_if_pending(); });
        timer->start(1500);
    }
    nh_log("added BokOPDS main navigation button");
    return true;
}

bool find_navigation_and_add_button() {
    const auto widgets = QApplication::allWidgets();
    for (QWidget* widget : widgets) {
        if (widget != nullptr && widget->inherits("MainNavView") &&
            add_navigation_button(static_cast<MainNavView*>(widget))) {
            return true;
        }
    }
    return false;
}

int initialize_application() {
    BokOPDSRefreshResolvedSymbols();
    QString firmware;
    QString hardware_id;
    if (!read_device_identity(&firmware, &hardware_id)) {
        nh_log("BokOPDS remains inactive because device identity is unavailable");
        return 0;
    }
    active_target = select_compatibility_target(firmware, hardware_id);
    if (active_target == nullptr) {
        nh_log("BokOPDS remains inactive on unknown hardware %s firmware %s",
               hardware_id.toLatin1().constData(), firmware.toLatin1().constData());
        return 0;
    }
    if (!active_target->enabled) {
        nh_log("BokOPDS compatibility target %s is disabled", active_target->id);
        active_target = nullptr;
        return 0;
    }
    if (!target_has_required_symbols(active_target)) {
        nh_log("BokOPDS target %s is missing required firmware symbols and remains inactive",
               active_target->id);
        active_target = nullptr;
        return 0;
    }
    nh_log("selected compatibility target %s", active_target->id);
    // Wait until the stock interface, and any other main-menu extension, has
    // finished constructing the navigation. Adding our button afterward avoids
    // competing hooks and makes initialization order irrelevant.
    QTimer::singleShot(0, [] {
        QTimer* discovery_timer = new QTimer(QApplication::instance());
        discovery_timer->setInterval(250);
        int* attempts = new int(0);
        QObject::connect(discovery_timer, &QTimer::timeout, [discovery_timer, attempts] {
            ++*attempts;
            if (find_navigation_and_add_button()) {
                discovery_timer->stop();
                discovery_timer->deleteLater();
                delete attempts;
            } else if (*attempts >= 40) {
                nh_log("could not find compatible main navigation after 10 seconds");
                discovery_timer->stop();
                discovery_timer->deleteLater();
                delete attempts;
            }
        });
        discovery_timer->start();
    });
    return 0;
}

} // namespace

NickelHook(.init = &initialize_application, .info = &BokOPDSInfo, .hook = nullptr,
           .dlsym = BokOPDSSymbols,
           .uninstall = &uninstall_application, )
