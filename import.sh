#!/bin/bash

NETBOX="http://netbox.tld"
TOKEN="token123"
DIR="./"
LOG="${DIR}import.log"
test -f nbimport.conf && source nbimport.conf

function extract_block() {
	file=$1
	block=$2
	grep "^%${block}%" -A 9999 ${file} | tail -n +2 | grep -B 9999 -m 1 "^%...%$" | head -n -1 | sed -e 's/ *$//g'
}

function curl_get(){
	query=$1
	curl -s -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" $NETBOX/api/$1
}
function curl_patch(){
	query=$1
	data=$(echo $2 |tr -s "'" "\"")
	curl -s --location --request PATCH -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" "$NETBOX/api/$1" --data "$data" 1>/dev/null
}
function curl_post(){
	query=$1
	data=$(echo $2 |tr -s "'" "\"")
	curl -s --location --request POST -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" "$NETBOX/api/$1" --data "$data" 1>/dev/null
}
function curl_delete(){
	query=$1
	curl -s --location --request DELETE -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" "$NETBOX/api/$1" 1>/dev/null
}
function mfr_id(){
	mfr=$1
	slug=$(grep -i -m1 "${mfr}" slug_dict.txt|cut -d ':' -f 1)
	id=$(echo "$jmfr_list" | grep "^${slug} " | cut -d ' ' -f 2)
	if [[ -z "${id}" ]] ; then
		echo "Manufacturer '${mfr}' $id $slug slug_dict.txt not found!"
		exit 1
	else
		echo $id
	fi
}

jmfr=$(curl_get "dcim/manufacturers/")
jmfr_list=$(echo "${jmfr}"|jq -c '.results[]|{slug,id}'|sed -e 's/^{.slug.:.//g' -e 's/.,.id.:/ /g' -e 's/}//g')

for hostinfofile in ${DIR}*.hostinfo ; do

# Обнуляем массивы данных с прошлых файлов
	unset DMI; declare -A DMI
	unset CPUManufacturer; declare -A CPUManufacturer
	unset CPUVersion; declare -A CPUVersion
	unset BLKVendor; declare -A BLKVendor
	unset BLKModel; declare -A BLKModel
	unset BLKSerial; declare -A BLKSerial
	unset BLKSize; declare -A BLKSize
	unset IFState; declare -A IFState
	unset IFMac; declare -A IFMac
	unset IFMtu; declare -A IFMtu
	unset IFType; declare -A IFType
	unset IFIPs; declare -A IFIPs
	unset SMTModel; declare -A SMTModel
	unset SMTSerial; declare -A SMTSerial
	unset SMTVendor; declare -A SMTVendor
	unset VDSState; declare -A VDSState
	unset VDSMemory; declare -A VDSMemory
	unset VDSVCPU; declare -A VDSVCPU
	unset VDSBLKData; declare -A VDSBLKData
	unset VDSBLKTotalsize; declare -A VDSBLKTotalsize

# Если файл есть, то режем на блоки и начинаем собирать инфу
	test -f ${hostinfofile} || break
	date >> ${LOG}
	echo "File ${hostinfofile}" >> ${LOG}
	hst=$(extract_block ${hostinfofile} "HST")
	ipa=$(extract_block ${hostinfofile} "IPA")
	dmd=$(extract_block ${hostinfofile} "DMD"|sed -e 's/: /:/g')
	blk=$(extract_block ${hostinfofile} "BLK"|sed -e 's/="/=/g' -e 's/ *" /|/g'|tr -d '"')
	smt=$(extract_block ${hostinfofile} "SMT"|sed -e 's/: */:/g')
	vds=$(extract_block ${hostinfofile} "VDS")

# Платформа
	DMI['SYSManufacturer']=$(echo "${dmd}"|grep -A 99 "^System Information"|grep -m1 "Manufacturer:"|cut -d ':' -f 2)
	DMI['SYSProductName']=$(echo "${dmd}"|grep -A 99 "^System Information"|grep -m1 "Product Name:"|cut -d ':' -f 2)
	DMI['SYSVersion']=$(echo "${dmd}"|grep -A 999 "^System Information"|grep -m1 "Version:"|cut -d ':' -f 2)
	DMI['SYSSerialNumber']=$(echo "${dmd}"|grep -A 99 "^System Information"|grep -m1 "Serial Number:"|cut -d ':' -f 2)
	DMI['BRDManufacturer']=$(echo "${dmd}"|grep -A 99 "^Base Board Information"|grep -m1 "Manufacturer:"|cut -d ':' -f 2)
	DMI['BRDProductName']=$(echo "${dmd}"|grep -A 99 "^Base Board Information"|grep -m1 "Product Name:"|cut -d ':' -f 2)
	DMI['BRDVersion']=$(echo "${dmd}"|grep -A 99 "^Base Board Information"|grep -m1 "Version:"|cut -d ':' -f 2)
	DMI['BRDSerialNumber']=$(echo "${dmd}"|grep -A 99 "^Base Board Information"|grep -m1 "Serial Number:"|cut -d ':' -f 2)

# Процессоры
	CPUCount=$(echo "${dmd}"|grep -c "^Processor Information")
	ptr=0
	for i in $(seq 1 ${CPUCount}) ; do
		ptr=$(( $(echo "${dmd}" | tail -n +$(($ptr+1)) | grep -m 1 -n "^Processor Information" | cut -d ':' -f 1) + ${ptr} ))
		DMICPUSocketDesignation=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Socket Designation:"|cut -d ':' -f 2)
		CPUManufacturer[$DMICPUSocketDesignation]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Manufacturer"|cut -d ':' -f 2)
		CPUVersion[$DMICPUSocketDesignation]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Version:"|cut -d ':' -f 2)
	done

# Память
	RAMCount=$(echo "${dmd}"|grep -c "^Memory Device")
	ptr=0
	idx=0
	for i in $(seq 1 ${RAMCount}) ; do
		idx=$(($idx + 1))
		ptr=$(( $(echo "${dmd}" | tail -n +$(($ptr + 1)) | grep -m 1 -n "^Memory Device" | cut -d ':' -f 1) + ${ptr} ))
		DMIMEMSize[$idx]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Size:"|cut -d ':' -f 2)
		DMIMEMLocator[$idx]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Locator:"|cut -d ':' -f 2)
		DMIMEMManufacturer[$idx]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Manufacturer:"|cut -d ':' -f 2)
		DMIMEMPartNumber[$idx]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Part Number:"|cut -d ':' -f 2)
	done

# Сеть
	IFCount=$(echo "${ipa}"|grep -c "^[[:digit:]]*:")
	ptr=0
	for i in $(seq 1 ${IFCount}) ; do
		ptr=$(( $(echo "${ipa}" | tail -n +$(($ptr+1)) | grep -m 1 -n "^[[:digit:]]*: " | cut -d ':' -f 1) + ${ptr} ))
		IFName=$(echo "${ipa}"|tail -n +${ptr}|grep -m1 "^[[:digit:]]*: "|cut -d ' ' -f 2|cut -d ':' -f 1)
		IFState[$IFName]=$(echo "${ipa}"|tail -n +${ptr}|grep -o -m1 "state [[:alpha:]]* " |cut -d ' ' -f 2)
		IFMtu[$IFName]=$(echo "${ipa}"|tail -n +${ptr}|grep -o -m1 "mtu [[:digit:]]* " |cut -d ' ' -f 2)
		if [[ ${i} -eq ${IFCount} ]] ; then
			IFBlock=$(echo -e "${ipa}\n\n\n"|tail -n +$(( ${ptr} + 1 )) |head -n -1)
		else
			IFBlock=$(echo "${ipa}"|tail -n +$(( ${ptr} + 1 )) |grep -B 999 -m1 "^[[:digit:]]*: "|head -n -1)
		fi
		IFMac[$IFName]=$(echo "${IFBlock}"|grep -o -m 1 "link\/[[:alpha:]]* [0-9a-f\:]*" | cut -d ' ' -f 2)
		IFType[$IFName]="0"
		if [[ $(echo "${IFBlock}"|grep " mii_status ") ]] ; then
			IFType[$IFName]="1000"
		fi
		IFIPs[$IFName]=$(echo "${IFBlock}"|grep -o "inet [0-9\./]*" | cut -d ' ' -f 2 | tr -s '\n' ' ')
	done

# BlockDevices
	while read -r i ; do
		BLKName=$(echo $i |cut -d '|' -f 1|cut -d '=' -f 2)
		BLKSizetmp=$(echo $i |cut -d '|' -f 2|cut -d '=' -f 2)
		BLKSize[$BLKName]="$(( $BLKSizetmp / 1000 / 1000 / 1000 )) Gb"
		BLKModel[$BLKName]=$(echo $i |cut -d '|' -f 3|cut -d '=' -f 2)
		BLKSerial[$BLKName]=$(echo $i |cut -d '|' -f 4|cut -d '=' -f 2)
		BLKVendor[$BLKName]=$(echo ${BLKModel[$BLKName]} |cut -d ' ' -f 1)
		test "${BLKModel[$BLKName]}" == ${BLKVendor[$BLKName]} && BLKVendor[$BLKName]=""
	done <<< $(echo "${blk}")

# SMART
	SMTCount=$(echo "${smt}"|grep -c "^%%SMT-")
	ptr=0
	for i in $(seq 1 ${SMTCount}) ; do
		ptr=$(( $(echo "${smt}" | tail -n +$(($ptr+1)) | grep -m 1 -n "^%%SMT-" | cut -d ':' -f 1) + ${ptr} ))
		SMTName=$(echo "${smt}"|tail -n +${ptr}|grep -m1 "^%%SMT-"|cut -d '-' -f 2)
		if [[ ${i} -eq ${SMTCount} ]] ; then
			SMTInfo=$(echo "${smt}"|tail -n +$(( ${ptr} + 1 )) |head -n -1)
		else
			SMTInfo=$(echo "${smt}"|tail -n +$(( ${ptr} + 1 )) |grep -B 999 -m1 "^%%SMT-"|head -n -1)
		fi
		SMTModel[$SMTName]=$(echo "${SMTInfo}"|grep -m1 "Device Model:"|cut -d ':' -f 2)
		test -z "${SMTModel[$SMTName]}" && SMTModel[$SMTName]=$(echo "${SMTInfo}"|grep -m1 "Product:"|cut -d ':' -f 2)
		SMTSerial[$SMTName]=$(echo "${SMTInfo}"|grep -m1 "Serial .umber:"|cut -d ':' -f 2)
		SMTVendor[$SMTName]=$(echo "${SMTInfo}"|grep -m1 "Vendor:"|cut -d ':' -f 2)
		test -z "${SMTVendor[$SMTName]}" && SMTVendor[$SMTName]=$(echo "${SMTModel[$SMTName]}"|cut -d ' ' -f 1)
		test "${SMTVendor[$SMTName]}" == "$SMTModel[$SMTName]" && SMTVendor[$SMTName]=""
	done

# Виртуалки
	VDSCount=$(echo "${vds}"|grep -c "^Domain: ")
	ptr=0
		for i in $(seq 1 ${VDSCount}) ; do
		ptr=$(( $(echo "${vds}" | tail -n +$(( $ptr + 1 )) | grep -m 1 -n "^Domain:" | cut -d ':' -f 1) + ${ptr} ))
		VDSName=$(echo "${vds}"|tail -n +${ptr} | grep -m 1 "^Domain:"|tr -d " '"|cut -d ':' -f 2)
		if [[ ${i} -eq ${VDSCount} ]] ; then
			 VDSDomInfo=$(echo "${vds}\n\n\n"|tail -n +$(( ${ptr} + 1 )) |head -n -1)
		else
			 VDSDomInfo=$(echo "${vds}"|tail -n +$(( ${ptr} + 1 )) |grep -B 999 -m1 "^Domain:"|head -n -1)
		fi
		VDSState[$VDSName]=$(echo "${VDSDomInfo}"|grep -m1 "state.state="|cut -d '=' -f 2)
		VDSMemory[$VDSName]=$(echo "${VDSDomInfo}"|grep -m1 "balloon.maximum="|cut -d '=' -f 2)
		VDSVCPU[$VDSName]=$(echo "${VDSDomInfo}"|grep -m1 "vcpu.current="|cut -d '=' -f 2)
		VDSBLKCount=$(echo "${VDSDomInfo}"|grep -m1 "block.count="|cut -d '=' -f 2)
		VDSBLKTotalsize[$VDSName]=0
		for i in $(seq 1 ${VDSBLKCount}) ; do
			VDSBLKName=$(echo "${VDSDomInfo}"|grep -m1 "block\.$(($i - 1))\.name="|cut -d '=' -f 2)
			VDSBLKPath=$(echo "${VDSDomInfo}"|grep -m1 "block\.$(($i - 1))\.path="|cut -d '=' -f 2)
			VDSBLKSize=$( expr $(echo "${VDSDomInfo}"|grep -m1 "block\.$(($i - 1))\.physical="|cut -d '=' -f 2) + 0 )
			VDSBLKSize=$(( $VDSBLKSize / 1024 / 1024 / 1024 ))
			VDSBLKData[$VDSName]="| ${VDSBLKName} | ${VDSBLKSize} | ${VDSBLKPath} |\r\n${VDSBLKData[$VDSName]}"
			VDSBLKTotalsize[$VDSName]=$(( ${VDSBLKTotalsize[$VDSName]} + $VDSBLKSize ))
		done
		VDSMemory[$VDSName]=$(( ${VDSMemory[$VDSName]} / 1024 ))
		VDSBLKData[$VDSName]="#### NBImport Block Devices\r\n| Name | Size | Path |\r\n| --- | --- | --- |\r\n${VDSBLKData[$VDSName]}\r\n***\r\n"
		test "${VDSState[$VDSName]}" == "5" && VDSState[$VDSName]="0" || VDSState[$VDSName]="1"
	done

# Исправляем SCSI модели и серийные номера, которые ограничены в 16 байт
	for i in "${!BLKSize[@]}" ; do
		if [[ -z "${BLKModel[$i]}" ]] ; then
			 BLKModel[$i]=${SMTModel[$j]}
		elif [[ "${SMTModel[$i]}" == *"${BLKModel[$i]}"* ]] ; then
			 BLKModel[$i]=${SMTModel[$i]}
		else
			 BLKModel[$i]="${SMTModel[$i]} (${BLKModel[$i]})"
		fi
		if [[ -z "${BLKSerial[$i]}" ]] ; then
			 BLKSerial[$i]=${SMTSerial[$i]}
		elif [[ "${SMTSerial[$i]}" == *"${BLKSerial[$i]}"* ]] ; then
			 BLKSerial[$i]=${SMTSerial[$i]}
		else
			 BLKSerial[$i]="${SMTSerial[$i]} (${BLKSerial[$i]})"
		fi
		BLKVendor[$i]=${SMTVendor[$i]}
	done

# Блок для отладки
	#for i in "${!DMI[@]}" ; do
	#	echo "$i => ${DMI[$i]}"
	#done
	#for i in "${!DMIMEMSize[@]}" ; do
	#	echo "$i => MF:${DMIMEMManufacturer[$i]} PN:${DMIMEMPartNumber[$i]} LOC:${DMIMEMLocator[$i]}"
	#done
	#for i in "${!IFState[@]}" ; do
	# 	echo -e "TYP: ${IFType[$i]} MAC:${IFMac[$i]} MTU:${IFMtu[$i]} IPs:${IFIPs[$i]} --- ${i}"
	#done
	#for i in "${!BLKSize[@]}" ; do
	#	echo "$i => MF:${BLKVendor[$i]} MOD:${BLKModel[$i]} SER:${BLKSerial[$i]} SZ:${BLKSize[$i]}"
	#done
	#for i in "${!VDSState[@]}" ; do
	#	echo "$i => MEM:${VDSMemory[$i]} CPU:${VDSVCPU[$i]} SIZE=${VDSBLKTotalsize[$i]} BLK:${VDSBLKData[$i]}"
	#done
	#exit 0

# Ищем устройсвто по серийному номеру и по имени
	jdevice=$(curl_get "dcim/devices/?serial=${DMI['SYSSerialNumber']}")
	device_id="notfound"
	if [[ $(echo "$jdevice"|jq .count) -ne 1 ]] ; then
		jdevice=$(curl_get "dcim/devices/?name=${hst}")
		if [[ $(echo "$jdevice"|jq .count) -eq 1 ]] ; then
			device_id=$(echo "$jdevice"|jq .results[0].id)
		fi
	else
		 device_id=$(echo "$jdevice"|jq .results[0].id)
	fi
	if [[ "${device_id}" == "notfound" ]] ; then
		echo "Device not found for ${hst} (sn:${DMI['SYSSerialNumber']})" >> ${LOG}
		break
	else
		jdevice=$(echo "$jdevice"|jq .results[0])
	fi

# Исправляем в netbox всё что можно
# Имя
	t=$(echo "$jdevice"|jq .name)
	if [[ "${t//\"/}" != "${hst}" ]] ; then
		echo "Change name ${t//\"/} -> $hst" >> ${LOG}
		curl_patch "dcim/devices/${device_id}/" "{'name':'${hst}'}"
	fi

# серийный номер
	t=$(echo "$jdevice"|jq .serial)
	if [[ "${t//\"/}" != "${DMI['SYSSerialNumber']}" ]] ; then
		echo "Change serial ${t//\"/} -> ${DMI['SYSSerialNumber']}" >> ${LOG}
		curl_patch "dcim/devices/${device_id}/" "{'serial':'${DMI['SYSSerialNumber']}'}"
	fi

# Виртуальные машины
	if [[ ${#VDSState[@]} -gt 0 ]] ; then
		jcluster_id=$(curl_get "dcim/devices/${device_id}/"|jq .cluster.id)
		jvms=$(curl_get "virtualization/virtual-machines/?cluster=${jcluster_id}"|jq ".results[]" -c)
		test "${jcluster_id}" == "null" && jcluster_id=$(curl_get "virtualization/clusters/?name=${hst}"|jq .results[0].id)
		if [[ "${jcluster_id}" == "null" ]] ; then
			echo "Create cluster ${hst}" >> ${LOG}
			curl_post "virtualization/clusters/" "{'name':'${hst}','type':'1','tags':['nbimport']}"
			jcluster_id=$(curl_get "virtualization/clusters/?name=${hst}"|jq .results[0].id)
		fi
		if [[ "${jcluster_id}" == "null" ]] ; then
			echo "ERROR! Can't fund cluster for ${hst}" >> ${LOG}
		else
			for vm in ${!VDSState[@]} ; do
				jvm=$(echo "${jvms}"|grep "name\":\"${vm}\"")
				jvms=$(echo "${jvms}"|grep -v "name\":\"${vm}\"")
				vm_post_data=""
				if [[ -z "${jvm}" ]] ; then
					jvm=$(curl_get "virtualization/virtual-machines/?name=${vm}"|jq ".results[0]" -c | grep "name\":\"${vm}\"")
					if [[ ! -z "${jvm}" ]] ; then
						vm_post_data=",'cluster':'${jcluster_id}'"
					fi
				fi
				if [[ "${jvm}" != *"vcpus\":${VDSVCPU[$vm]}"* ]] ; then vm_post_data="${vm_post_data},'vcpus':${VDSVCPU[$vm]}" ; fi
				if [[ "${jvm}" != *"memory\":${VDSMemory[$vm]}"* ]] ; then vm_post_data="${vm_post_data},'memory':'${VDSMemory[$vm]}'" ; fi
				if [[ "${jvm}" != *"disk\":${VDSBLKTotalsize[$vm]}"* ]] ; then vm_post_data="${vm_post_data},'disk':${VDSBLKTotalsize[$vm]}" ; fi
				if [[ "${jvm}" != *"status\":{\"value\":${VDSState[$vm]}"* ]] ; then vm_post_data="${vm_post_data},'status':${VDSState[$vm]}" ; fi
				jvm_blkcomment=$(echo "$jvm" | jq .comments|sed -e 's/^"//' -e 's/"$//' -e 's/\*\*\*\\r\\n.*$/***\\r\\n/')
				vm_post_data_comment=""
				if [[ "${jvm_blkcomment}" != "${VDSBLKData[$vm]}" ]] ; then
					jvm_comment=$(echo "$jvm" | jq .comments|sed -e 's/^"//' -e 's/"$//' -e 's/^.*\*\*\*\\r\\n//')
					vm_post_data_comment=",'comments':'${VDSBLKData[$vm]}${jvm_comment}'"
				fi
				if [[ ! -z "${vm_post_data}" ]] ; then
					if [[ -z "${jvm}" ]] ; then
						echo "Create VM $vm - ${vm_post_data}" >> ${LOG}
						curl_post "virtualization/virtual-machines/" "{ 'tags':['nbimport'] ${vm_post_data}${vm_post_data_comment},'name':'${vm}','cluster':'${jcluster_id}' }"
					else
						jvm_id=$(echo "$jvm" | jq .id)
						echo "Change VM $vm($jvm_id) - ${vm_post_data}" >> ${LOG}
						curl_patch "virtualization/virtual-machines/${jvm_id}/" "{ 'tags':['nbimport'] ${vm_post_data}${vm_post_data_comment} }"
					fi
				fi
			done
			for lostvm in $(echo "${jvms}" | jq .name | tr -d '"') ; do
				jvm=$(echo "${jvms}"|grep "name\":\"${lostvm}\"")
				if [[ "${jvm}" == *"status\":{\"value\":1"* ]] ; then
					jvm_id=$(echo "$jvm" | jq .id)
					echo "Unknown or Lost VM ${lostvm}. Set status to 'Offline'" >> ${LOG}
					curl_patch "virtualization/virtual-machines/${jvm_id}/" "{ 'status':0 }"
				fi
			done
		fi
	fi

# Интерфейсы
	jiface=$(curl_get "dcim/interfaces/?device_id=${device_id}")
	jiface_names=$(echo -e "$jiface" | jq .results[].name|tr -d '"'|tr -s '\n' ' ')
	for i in "${!IFState[@]}" ; do
		if [[ "${i}" =~ ^(eth|bond|enp|p|vlan|br) ]] ; then
			if [[ " ${jiface_names} " != *" ${i} "* ]] ; then
				echo "Create interface $i - mtu ${IFMtu[$i]} mac ${IFMac[$i]} type ${IFType[$i]}" >> ${LOG}
				curl_post "dcim/interfaces/" "{ 'device':'${device_id}','name':'${i}','form_factor':'${IFType[$i]}','mac_address':'${IFMac[$i]}','mtu':'${IFMtu[$i]}','tags':['nbimport'] }"
			fi
		fi
	done

# ip адреса
	jiface=$(curl_get "dcim/interfaces/?device_id=${device_id}")
	jips=$(curl_get "ipam/ip-addresses/?device_id=${device_id}")
	jips_string=$(echo -e "$jips" | jq .results[].address|tr -d '"'|tr -s '\n' ' ')
	for i in "${!IFState[@]}" ; do
		if [[ "${i}" =~ ^(eth|bond|enp|p|vlan|br) ]] ; then
			if [[ ! -z "${IFIPs[$i]}" ]] ; then
				for ip in "${IFIPs[$i]}" ; do
					if [[ " ${jips_string} " != *" ${ip} "* ]] ; then
						jiface_id=$(echo "${jiface}"| jq ."results[]|select(.name == \"$i\").id")
						echo "Create ip ${ip} - on ${i} (${jiface_id})" >> ${LOG}
						curl_post "ipam/ip-addresses/" "{ 'address':'${ip}','family':'4','status':'1','interface':'${jiface_id}','tags':['nbimport'] }"
					fi
				done
			fi
		fi
	done

# Инвентори
	jinventory=$(curl_get "dcim/inventory-items/?device_id=${device_id}" |jq '.results[]' -c)
	jinventory_ids=$(curl_get "dcim/inventory-items/?device_id=${device_id}" |jq .'results[]|select(.tags != ["nbignore"]).id' | tr -d '"')

# Материнская плата
	jbaseboard=$(echo "${jinventory}" | grep "name\":\"Base Board Information\"")
	if [[ -z "${jbaseboard}" ]] ; then
		echo "Create inventory Base Board Information ${DMI['BRDManufacturer']} ${DMI['BRDProductName']} ${DMI['BRDSerialNumber']}" >> ${LOG}
		curl_post "dcim/inventory-items/" "{ 'device':'${device_id}','name':'Base Board Information','manufacturer':'$(mfr_id "${DMI['BRDManufacturer']}")','part_id':'${DMI['BRDProductName']}','serial':'${DMI['BRDSerialNumber']}','discovered':'true','tags':['nbimport','inv-baseboard'] }"
	else
		jinventory_ids=$(echo "${jinventory_ids}"|grep -v ^$(echo ${jbaseboard}|jq .id))
	fi

# Процессоры
	for i in "${!CPUManufacturer[@]}" ; do
		post_data="{ 'device':'${device_id}','name':'${i}','manufacturer':'$(mfr_id "${CPUManufacturer[$i]}")','part_id':'${CPUVersion[$i]}','discovered':'true','tags':['nbimport','inv-cpu'] }"
		for j in $(echo "${jinventory}"| grep "name\":\"${i}\""|jq .id) ; do
			if [[ -z "${post_data}" ]] ; then
				echo "Delete duplicate inventory with name=${i} and id=${j}" >> ${LOG}
				curl_delete "dcim/inventory-items/${j}"
			else
				jcpu=$(echo "${jinventory}" | grep -m 1 "name\":\"${i}\"")
				if [[ "${jcpu}" != *"part_id\":\"${CPUVersion[$i]}\""* ]] ; then
					echo "Change inventory ${post_data}" >> ${LOG}
					curl_patch "dcim/inventory-items/${j}/" "${post_data}"
				fi
				post_data=""
			fi
			jinventory_ids=$(echo "${jinventory_ids}"|grep -v ^${j})
		done
		if [[ ! -z "${post_data}" ]] ; then
			echo "Create inventory ${post_data}" >> ${LOG}
			curl_post "dcim/inventory-items/" "${post_data}"
		fi
	done

# Память
	for i in "${!DMIMEMLocator[@]}" ; do
		post_data="{'device':'$device_id','name':'${DMIMEMLocator[$i]}','manufacturer':'$(mfr_id "${DMIMEMManufacturer[$i]}")','part_id':'${DMIMEMPartNumber[$i]}','description':'${DMIMEMSize[$i]}','discovered':'true','tags':['nbimport','inv-memdevice'] }"
		for j in $(echo "${jinventory}"| grep "name\":\"${DMIMEMLocator[$i]}\""|jq .id) ; do
			if [[ -z "${post_data}" ]] ; then
				echo "Delete duplicate inventory with name=${i} and id=${j}" >> ${LOG}
				curl_delete "dcim/inventory-items/${j}"
			else
				jmem=$(echo "${jinventory}" | grep -m 1 "name\":\"${DMIMEMLocator[$i]}\"")
				if [[ "${jmem}" != *"part_id\":\"${DMIMEMPartNumber[$i]}\""* || "${jmem}" != *"description\":\"${DMIMEMSize[$i]}\""* ]] ; then
					echo "Change inventory ${post_data}" >> ${LOG}
					curl_patch "dcim/inventory-items/${j}/" "${post_data}"
				fi
				post_data=""
			fi
			jinventory_ids=$(echo "${jinventory_ids}"|grep -v ^${j})
		done
		if [[ ! -z "${post_data}" ]] ; then
			echo "Create inventory ${post_data}" >> ${LOG}
			curl_post "dcim/inventory-items/" "${post_data}"
		fi
	done

# BlockDevices
	for i in "${!BLKSize[@]}" ; do
		post_data="{'device':'$device_id','name':'${i}','manufacturer':'$(mfr_id "${BLKVendor[$i]}")','part_id':'${BLKModel[$i]}','description':'${BLKSize[$i]}','serial':'${BLKSerial[$i]}','discovered':'true','tags':['nbimport','inv-blockdev'] }"
		for j in $(echo "${jinventory}"| grep "name\":\"${i}\""|jq .id) ; do
			if [[ -z "${post_data}" ]] ; then
				echo "Delete duplicate inventory with name=${i} and id=${j}" >> ${LOG}
				curl_delete "dcim/inventory-items/${j}"
			else
				jblk=$(echo "${jinventory}" | grep "name\":\"${i}\"")
				if [[ "${jblk}" != *"part_id\":\"${BLKModel[$i]}\""* || "${jblk}" != *"serial\":\"${BLKSerial[$i]}\""* || "${jblk}" != *"description\":\"${BLKSize[$i]}\""* ]] ; then
					echo "Change inventory ${post_data}" >> ${LOG}
					curl_patch "dcim/inventory-items/${j}/" "${post_data}"
				fi
				post_data=""
			fi
			jinventory_ids=$(echo "${jinventory_ids}"|grep -v ^${j})
		done
		if [[ ! -z "${post_data}" ]] ; then
			echo "Create inventory ${post_data}" >> ${LOG}
			curl_post "dcim/inventory-items/" "${post_data}"
		fi
	done

# Предупреждаем о лишних
	for i in $jinventory_ids ; do
		name=$(echo "${jinventory}"|grep "id\":${i}"|jq .name)
		part_id=$(echo "${jinventory}"|grep "id\":${i}"|jq .part_id)
		discovered=$(echo "${jinventory}"|grep "id\":${i}"|jq .discovered)
		if [[ "${discovered}" == "true" ]] ; then
			echo "Delete missing discovered inventory with name=${name} and id=${i}" >> ${LOG}
		fi
		# echo "Found missing or manually added inventory with id=${i} name=${name} part_id=${part_id}. Set 'nbignore' tag to suppress this message"  >> ${LOG}
	done
	rm -f ${hostinfofile}
done
