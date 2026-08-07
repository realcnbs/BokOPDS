#include <NickelHook.h>

#include <QApplication>
#include <QDir>
#include <QFile>
#include <QHBoxLayout>
#include <QProcess>
#include <QPushButton>
#include <QString>
#include <QTimer>
#include <QWidget>

#include <cerrno>
#include <signal.h>
#include <sys/types.h>

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

void (*MainNavButton_construct)(MainNavButton*, QWidget* parent);
void (*MainNavButton_setPixmap)(MainNavButton*, const QString& name);
void (*MainNavButton_setActivePixmap)(MainNavButton*, const QString& name);
void (*MainNavButton_setText)(MainNavButton*, const QString& text);
PlugWorkflowManager* (*PlugWorkflowManager_sharedInstance)();
void (*PlugWorkflowManager_sync)(PlugWorkflowManager*);

struct nh_info BokOPDSInfo = {
    .name = "BokOPDS",
    .desc = "Direct OPDS catalog launcher.",
    .uninstall_flag = "/mnt/onboard/.adds/bokopds/uninstall",
    .uninstall_xflag = nullptr,
    .failsafe_delay = 3,
};

struct nh_dlsym BokOPDSSymbols[] = {
    {.name = "_ZN13MainNavButtonC1EP7QWidget",
     .out = nh_symoutptr(MainNavButton_construct),
     .desc = "main navigation button constructor",
     .optional = false},
    {.name = "_ZN13MainNavButton9setPixmapERK7QString",
     .out = nh_symoutptr(MainNavButton_setPixmap),
     .desc = "main navigation icon setter",
     .optional = false},
    {.name = "_ZN13MainNavButton15setActivePixmapERK7QString",
     .out = nh_symoutptr(MainNavButton_setActivePixmap),
     .desc = "active main navigation icon setter",
     .optional = false},
    {.name = "_ZN13MainNavButton7setTextERK7QString",
     .out = nh_symoutptr(MainNavButton_setText),
     .desc = "main navigation label setter",
     .optional = false},
    {.name = "_ZN19PlugWorkflowManager14sharedInstanceEv",
     .out = nh_symoutptr(PlugWorkflowManager_sharedInstance),
     .desc = "library refresh manager",
     .optional = true},
    {.name = "_ZN19PlugWorkflowManager4syncEv",
     .out = nh_symoutptr(PlugWorkflowManager_sync),
     .desc = "library refresh action",
     .optional = true},
    {0},
};

void refresh_library_if_pending();

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
    const bool started = QProcess::startDetached(QStringLiteral("/bin/sh"),
                                   QStringList() << QStringLiteral("-c")
                                                 << QStringLiteral("exec \"") +
                                                        QString::fromLatin1(launcher_path) +
                                                        QStringLiteral("\""),
                                   QString::fromLatin1(application_directory), &process_id);
    if (started && PlugWorkflowManager_sharedInstance != nullptr &&
        PlugWorkflowManager_sync != nullptr) {
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
    if (PlugWorkflowManager_sharedInstance == nullptr || PlugWorkflowManager_sync == nullptr) {
        nh_log("library refresh is pending but the required firmware symbols are unavailable");
        return;
    }
    PlugWorkflowManager* workflow = PlugWorkflowManager_sharedInstance();
    if (workflow == nullptr) {
        nh_log("library refresh is pending but the workflow manager is unavailable");
        return;
    }
    PlugWorkflowManager_sync(workflow);
    if (!QFile::remove(QString::fromLatin1(library_refresh_marker))) {
        nh_log("library refresh was requested but the pending marker could not be removed");
        return;
    }
    nh_log("requested native library refresh for newly downloaded publications");
}

bool add_navigation_button(MainNavView* view) {
    if (view->findChild<QWidget*>(QStringLiteral("bokopdsButton")) != nullptr) {
        return true;
    }
    QHBoxLayout* layout = view->findChild<QHBoxLayout*>();
    if (layout == nullptr) {
        return false;
    }

    // MainNavButton is a private firmware class. This storage size was checked
    // on the only firmware accepted by the installer. Use the C++ allocator so
    // QObject/Qt destruction calls the matching operator delete.
    MainNavButton* button = reinterpret_cast<MainNavButton*>(
        ::operator new(512, std::nothrow));
    if (button == nullptr) {
        nh_log("could not allocate main navigation button");
        return false;
    }
    MainNavButton_construct(button, view->parentWidget());
    MainNavButton_setText(button, QStringLiteral("BokOPDS"));
    MainNavButton_setPixmap(button, QStringLiteral("/mnt/onboard/.adds/bokopds/menu-book.png"));
    MainNavButton_setActivePixmap(
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
