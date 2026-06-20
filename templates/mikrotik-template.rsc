/system script add name="rename-interfaces" dont-require-permissions=yes source={
    :global RenameDone

    :if ($RenameDone = true) do={
        :log info "Rename script already completed. Skipping."
        :return
    }

    :local maxWait 60
    :local waited 0
    :local done false

    :log info "=== Waiting for interfaces to initialize ==="

    :while ($waited < $maxWait && $done = false) do={
        :local etherCount [:len [/interface ethernet find]]

        :if ($etherCount >= @@ETHER_PORTS@@) do={
            :log info "Interfaces ready after $waited seconds. Renaming..."

            /interface ethernet
            @@ETHER_NAMES@@
            set [ find default-name=ether1 ] disable-running-check=no name=qsfp28-1-1
            set [ find default-name=ether2 ] disable-running-check=no name=qsfp28-2-1
            set [ find default-name=ether3 ] disable-running-check=no name=sfp28-1
            set [ find default-name=ether4 ] disable-running-check=no name=sfp28-2
            set [ find default-name=ether5 ] disable-running-check=no name=sfp28-3
            set [ find default-name=ether6 ] disable-running-check=no name=sfp28-4
            set [ find default-name=ether7 ] disable-running-check=no name=sfp28-5
            set [ find default-name=ether8 ] disable-running-check=no name=sfp28-6
            set [ find default-name=ether9 ] disable-running-check=no name=sfp28-7
            set [ find default-name=ether10 ] disable-running-check=no name=sfp28-8
            set [ find default-name=ether11 ] disable-running-check=no name=sfp28-9
            set [ find default-name=ether12 ] disable-running-check=no name=sfp28-10
            set [ find default-name=ether13 ] disable-running-check=no name=sfp28-11
            set [ find default-name=ether14 ] disable-running-check=no name=sfp28-12

            :set done true
            :set RenameDone true
            :log info "Interface rename complete. Waiting 10s before cleanup..."

            :delay 10s

            # Cleanup default DHCP client
            :log info "Removing default DHCP client..."
            /ip dhcp-client remove 0

            :log info "Post-rename cleanup complete."
        } else={
            :delay 2s
            :set waited ($waited + 2)
        }
    }

    :if ($done = false) do={
        :log warning "Interface rename timeout after $maxWait seconds."
    }
}

/system scheduler add name="rename-on-boot" on-event=rename-interfaces \
    start-time=startup interval=0s policy=read,write,test

/system identity set name="@@NAME@@"
