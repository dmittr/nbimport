# nbimport
Netbox importer for vfarms

- Paste you netbox url and token first
- Use method you mostly like to reach vfarm (libvirt host) and gather hostinfo file.
hostinfo file must contain output of following comman

`echo %HST%;hostname -f;echo %IPA%;sudo ip -detail address show;echo %DMD%;sudo dmidecode;echo %BLK%;sudo lsblk -dbP --output NAME,SIZE,MODEL,SERIAL;echo %SMT%;sudo which smartctl && for i in $(lsblk -d --output NAME|tail -n +2); do echo %%SMT-$i; sudo smartctl -i /dev/$i; done ;echo %VDS%; sudo virsh domstats;echo %END%`

In my case most convinient way is 
`ssh vfarm 'echo %HST%;hostname -f;echo %IPA%;sudo ip -detail address show;echo %DMD%;sudo dmidecode;echo %BLK%;sudo lsblk -dbP --output NAME,SIZE,MODEL,SERIAL;echo %SMT%;sudo which smartctl && for i in $(lsblk -d --output NAME|tail -n +2); do echo %%SMT-$i; sudo smartctl -i /dev/$i; done ;echo %VDS%; sudo virsh domstats;echo %END%' | cat > $(hostname -f)_$(date +%s).hostinfo`



Limitations:
- Device (physical server) must be created mannualy with matching hostname or serial number. 
- There is no deletion of interfaces, ip-addresses or VMs
