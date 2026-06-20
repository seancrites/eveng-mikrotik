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

        :if ($etherCount >= 9) do={   # Adjust to your port count
            :log info "Interfaces ready after $waited seconds. Renaming..."

            /interface ethernet
            set [find default-name=ether9]  disable-running-check=no name=sfp-sfpplus1

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

/system identity set name="RB5009"
