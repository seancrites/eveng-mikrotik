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

        :if ($etherCount >= 20) do={   # Adjust to your port count
            :log info "Interfaces ready after $waited seconds. Renaming..."

            /interface ethernet
            set [find default-name=ether1]  disable-running-check=no name=qsfp28-1-1
            set [find default-name=ether2]  disable-running-check=no name=qsfp28-2-1
            set [find default-name=ether3]  disable-running-check=no name=qsfp28-3-1
            set [find default-name=ether4]  disable-running-check=no name=qsfp28-4-1
            set [find default-name=ether5]  disable-running-check=no name=qsfp28-5-1
            set [find default-name=ether6]  disable-running-check=no name=qsfp28-6-1
            set [find default-name=ether7]  disable-running-check=no name=qsfp28-7-1
            set [find default-name=ether8]  disable-running-check=no name=qsfp28-8-1
            set [find default-name=ether9]  disable-running-check=no name=qsfp28-9-1
            set [find default-name=ether10] disable-running-check=no name=qsfp28-10-1
            set [find default-name=ether11] disable-running-check=no name=qsfp28-11-1
            set [find default-name=ether12] disable-running-check=no name=qsfp28-12-1
            set [find default-name=ether13] disable-running-check=no name=qsfp28-13-1
            set [find default-name=ether14] disable-running-check=no name=qsfp28-14-1
            set [find default-name=ether15] disable-running-check=no name=qsfp28-15-1
            set [find default-name=ether16] disable-running-check=no name=qsfp28-16-1
            set [find default-name=ether17] disable-running-check=no name=sfp28-1
            set [find default-name=ether18] disable-running-check=no name=sfp28-2
            set [find default-name=ether19] disable-running-check=no name=sfp28-3
            set [find default-name=ether20] disable-running-check=no name=sfp28-4

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
