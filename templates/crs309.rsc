/system script
add dont-require-permissions=yes name=rename-interfaces owner=admusr policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source="\
    \n    :global RenameDone\
    \n\
    \n    :if (\$RenameDone = true) do={\
    \n        :log info \"Rename script already completed. Skipping.\"\
    \n        :return\
    \n    }\
    \n\
    \n    :local maxWait 60\
    \n    :local waited 0\
    \n    :local done false\
    \n\
    \n    :log info \"=== Waiting for interfaces to initialize ===\"\
    \n\
    \n    :while (\$waited < \$maxWait && \$done = false) do={\
    \n        :local etherCount [:len [/interface ethernet find]]\
    \n\
    \n        :if (\$etherCount >= 8) do={   # Adjust to your port count\
    \n            :log info \"Interfaces ready after \$waited seconds. Renamin\
    g...\"\
    \n\
    \n            /interface ethernet\
    \n            set [find default-name=ether1]  disable-running-check=no nam\
    e=sfp-sfpplus1\
    \n            set [find default-name=ether2]  disable-running-check=no nam\
    e=sfp-sfpplus2\
    \n            set [find default-name=ether3]  disable-running-check=no nam\
    e=sfp-sfpplus3\
    \n            set [find default-name=ether4]  disable-running-check=no nam\
    e=sfp-sfpplus4\
    \n            set [find default-name=ether5]  disable-running-check=no nam\
    e=sfp-sfpplus5\
    \n            set [find default-name=ether6]  disable-running-check=no nam\
    e=sfp-sfpplus6\
    \n            set [find default-name=ether7]  disable-running-check=no nam\
    e=sfp-sfpplus7\
    \n            set [find default-name=ether8]  disable-running-check=no nam\
    e=sfp-sfpplus8\
    \n\
    \n            :set done true\
    \n            :set RenameDone true\
    \n            :log info \"Interface rename complete. Waiting 10s before cl\
    eanup...\"\
    \n\
    \n            :delay 10s\
    \n\
    \n            # Cleanup default DHCP client\
    \n            :log info \"Removing default DHCP client...\"\
    \n            /ip dhcp-client remove 0\
    \n\
    \n            :log info \"Post-rename cleanup complete.\"\
    \n        } else={\
    \n            :delay 2s\
    \n            :set waited (\$waited + 2)\
    \n        }\
    \n    }\
    \n\
    \n    :if (\$done = false) do={\
    \n        :log warning \"Interface rename timeout after \$maxWait seconds.\
    \"\
    \n    }\
    \n"

/system scheduler add name="rename-on-boot" on-event=rename-interfaces \
    start-time=startup interval=0s policy=read,write,test
