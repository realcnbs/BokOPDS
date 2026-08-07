-- BokOPDS intentionally does not embed a Wi-Fi network configuration client.
-- Configure networks in the stock reader interface before launching the app.
-- The device layer can still restore an already configured connection and the
-- network manager can still report link and internet status.

local Backend = {}

local function unavailable()
    return nil, "Configure Wi-Fi in the reader interface, then return to BokOPDS."
end

function Backend.init(network_manager, options)
    network_manager.bokopds_can_configure_wifi = false
    network_manager.wpa_supplicant = {
        ctrl_interface = options and options.ctrl_interface,
    }
    network_manager.getConfiguredNetworks = function() return {} end
    network_manager.getNetworkList = unavailable
    network_manager.getCurrentNetwork = function() return nil end
    network_manager.authenticateNetwork = unavailable
    network_manager.disconnectNetwork = function() return false end
end

return Backend
