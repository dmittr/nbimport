#!/bin/bash

NETBOX="http://netbox.tld"
TOKEN="mytoken"
HOSTINFO_DIR="/home/nbimport/"
HOSTINFO_SUFFIX="hostinfo"
HOSTINFO_READY_DIR="/home/nbimport/ready"

PID="/tmp/nbimport.pid"
LOG="/home/nbimport/import.log"
LOG2="/opt/nbimport_import.log"
LOG_LEVEL=3
LOG_HOOK=3
LOG_STDOUT=1
HOOK_SCRIPT="/bin/true"
NONAME_MANUFACTURER=1
LOGDATEFORMAT="%Y.%m.%d_%H:%M:%S"

DIR=$(dirname $(readlink -f $0))
SLUG_DICT=$(cat ${DIR}/slug_dict.txt)

test -f "${DIR}/nbimport.conf" && source "${DIR}/nbimport.conf" || exit 1

test -f "${PID}" && exit 0
trap "rm -f ${PID}" EXIT
echo "$$" > ${PID}

LOG_LEVEL=$(($LOG_LEVEL + 0))
LOG_STDOUT=$(($LOG_STDOUT + 0))

function log(){
	msg_level=$(($1 + 0))
	test $msg_level -eq 5 && prefix="FATAL"
	test $msg_level -eq 4 && prefix="ERROR"
	test $msg_level -eq 3 && prefix="WARNN"
	test $msg_level -eq 2 && prefix="INFRM"
	test $msg_level -eq 1 && prefix="DEBUG"
	msg="$(date +${LOGDATEFORMAT}) ${prefix}: $2"
	test -f "${LOG2}" && echo "${msg}" >> $LOG2

	if [[ ${LOG_LEVEL} -le $msg_level ]] ; then
		test ${LOG_STDOUT} -gt 0 && echo "${msg}"
		test -f ${LOG} || touch ${LOG} 2>/dev/null
		test -f ${LOG} || echo "Can't create log file ${LOG}"
		test -f ${LOG} || exit 1
		echo "${msg}" >> $LOG
	fi
	if [[ ${LOG_HOOK} -le $msg_level ]] ; then
		test -x "${HOOK_SCRIPT}" && ${HOOK_SCRIPT} "$msg"
	fi
}
function die() {
	log 5 "$1"
}
function extract_block() {
	file=$1
	block=$2
	grep "^%${block}%" -A 9999 ${file} | tail -n +2 |grep  -B 9999 -m 1 "^%...%$" | head -n -1 | sed -e 's/ *$//g'
}
function curl_get(){
	query="$1"
	out=$(${C} -s -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" $NETBOX/api/${query})
	CurlOut="${out}"
	CurlStatus="GET exit-code=$?, req=${query}, out=${out:0:100}"
}
function curl_patch(){
	query="$1"
	data=$(echo $2 |tr "'" "\"")
	out=$(${C} -s --location --request PATCH -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" "$NETBOX/api/${query}" --data "$data")
	CurlOut="${out}"
	CurlStatus="PATCH exit-code=$?, req=${query}, data=${data}, out=${out:0:100}"
}
function curl_post(){
	query="$1"
	data=$(echo $2 |tr "'" "\"")
	out=$(${C} -s --location --request POST -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" "$NETBOX/api/${query}" --data "$data")
	CurlOut="${out}"
	CurlStatus="POST exit-code=$?, req=${query}, data=${data}, out=${out:0:100}"
}
function curl_delete(){
	query="$1"
	out=$(${C} -s --location --request DELETE -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" "$NETBOX/api/${query}")
	CurlOut="${out}"
	CurlStatus="DELETE exit-code=$?, req=${query}"
}

function mfr_id(){
	string=$(echo $1|tr -d "-" | tr -d ' '| grep -o "[[:alpha:]]*")
	ret=""
	curl_get "dcim/manufacturers/"
	test -z "${ManufacturersList}" && ManufacturersList=$(echo "${CurlOut}"|${J} -c '.results[]|{slug,id}'|sed -e 's/\"[a-Z]*\"://g' -e 's/[\{\}\"]//g'|tr -d "-" | tr -d ' ')
	while read -r i ; do
		echo ${string} | grep -q -i "^$(echo $i | cut -d ',' -f 1)"
		if [[ $? -eq 0 ]] ; then
			test -z "${ret}" && ret=$(echo $i | cut -d ',' -f 2)
		fi
	done <<< $(echo "${ManufacturersList}")
	while read -r i ; do
		for j in $(echo $i|cut -d ':' -f 2-|tr ',' ' ') ; do
			echo ${string} | grep -q "^${j}"
			if [[ $? -eq 0 ]] ; then
				test -z "${ret}" && ret=$(echo "${ManufacturersList}" | grep "^$(echo $i|cut -d ':' -f 1)" | cut -d ',' -f 2)
			fi			
		done
	done <<< $(echo "${SLUG_DICT}")
	test -z "${ret}" && ret=$NONAME_MANUFACTURER
	echo "${ret}"
}

log 2 "Start"

test -d "${HOSTINFO_DIR}" || die "HOSTINFO_DIR ${HOSTINFO_DIR} not found"
test -d "${HOSTINFO_READY_DIR}" || log 2 "Creating HOSTINFO_READY_DIR ${HOSTINFO_READY_DIR}"
test -d "${HOSTINFO_READY_DIR}" || mkdir "${HOSTINFO_READY_DIR}"
test -d "${HOSTINFO_READY_DIR}" || die "HOSTINFO_READY_DIR ${HOSTINFO_READY_DIR} not crated"
test $(which jq 2>/dev/null) || die "jq not found"
test $(which curl 2>/dev/null) || die "curl not found"

J=$(which jq)
C=$(which curl)

HOSTINFO_FILES=$(ls ${HOSTINFO_DIR}*.${HOSTINFO_SUFFIX} 2>/dev/null)
test -z "${HOSTINFO_FILES}" && log 1 "No files to process from ${HOSTINFO_DIR}*.${HOSTINFO_SUFFIX}"
test -z "${HOSTINFO_FILES}" && exit 0

mfr_id "noname" > /dev/null
log 2 "Got Manufacturers list ${#ManufacturersList} bytes long"

for hostinfofile in ${HOSTINFO_FILES} ; do
	log 1 "File=${hostinfofile} from ${HOSTINFO_DIR} by suffix ${HOSTINFO_SUFFIX}"

	unset DMI; declare -A DMI
	unset CPUManufacturer; declare -A CPUManufacturer
	unset CPUVersion; declare -A CPUVersion
	unset DMIMEMSize; declare -A DMIMEMSize
	unset DMIMEMLocator; declare -A DMIMEMLocator
	unset DMIMEMManufacturer; declare -A DMIMEMManufacturer
	unset DMIMEMPartNumber; declare -A DMIMEMPartNumber
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
	unset vmhost
	unset vmhost_id

	test -f ${hostinfofile} || log 4 "${hostinfofile} not found"
	test -f ${hostinfofile} || break
	log 2 "Processing $(basename ${hostinfofile})"

	hst=$(extract_block ${hostinfofile} "HST")
	hyp=$(extract_block ${hostinfofile} "HYP"|grep "Hypervisor detected"|tr -d ' '|cut -d : -f 2)
	ipa=$(extract_block ${hostinfofile} "IPA")
	dmd=$(extract_block ${hostinfofile} "DMD"|sed -e 's/: /:/g')
	blk=$(extract_block ${hostinfofile} "BLK"|sed -e 's/="/=/g' -e 's/ *" /|/g'|tr -d '"')
	smt=$(extract_block ${hostinfofile} "SMT"|sed -e 's/: */:/g')
	vds=$(extract_block ${hostinfofile} "VDS")
	log 1 "hst=${hst}, hyp=${hyp}, ipa=${#ipa} bytes, dmd=${#dmd} bytes, blk=${#blk} bytes, smt=${#smt} bytes, vds=${#vds} bytes"
	if [[ -z "${hst}" ]] ; then
		log 5 "$(basename ${hostinfofile}) hostname not found! Skip this file."
		mv ${hostinfofile} ${HOSTINFO_READY_DIR}
		break
	fi

	if [[ -z "${hyp}" ]] ; then
# Платформа
		log 1 "${hst} is not a VM"
		DMI['SYSManufacturer']=$(echo "${dmd}"|grep -A 99 "^System Information"|grep -m1 "Manufacturer:"|cut -d ':' -f 2)
		DMI['SYSProductName']=$(echo "${dmd}"|grep -A 99 "^System Information"|grep -m1 "Product Name:"|cut -d ':' -f 2)
		DMI['SYSVersion']=$(echo "${dmd}"|grep -A 999 "^System Information"|grep -m1 "Version:"|cut -d ':' -f 2)
		DMI['SYSSerialNumber']=$(echo "${dmd}"|grep -A 99 "^System Information"|grep -m1 "Serial Number:"|cut -d ':' -f 2|sed -e 's/[^a-zA-Z0-9-]//g')
		DMI['BRDManufacturer']=$(echo "${dmd}"|grep -A 99 "^Base Board Information"|grep -m1 "Manufacturer:"|cut -d ':' -f 2)
		DMI['BRDProductName']=$(echo "${dmd}"|grep -A 99 "^Base Board Information"|grep -m1 "Product Name:"|cut -d ':' -f 2)
		DMI['BRDVersion']=$(echo "${dmd}"|grep -A 99 "^Base Board Information"|grep -m1 "Version:"|cut -d ':' -f 2)
		DMI['BRDSerialNumber']=$(echo "${dmd}"|grep -A 99 "^Base Board Information"|grep -m1 "Serial Number:"|cut -d ':' -f 2|sed -e 's/[^a-zA-Z0-9-]//g')
		log 1 "${hst} SYSManufacturer=${DMI['SYSManufacturer']}, SYSProductName=${DMI['SYSProductName']}, SYSVersion=${DMI['SYSVersion']}, SYSSerialNumber=${DMI['SYSSerialNumber']}, BRDManufacturer=${DMI['BRDManufacturer']}, BRDProductName=${DMI['BRDProductName']}, BRDVersion=${DMI['BRDVersion']}, BRDSerialNumber=${DMI['BRDSerialNumber']}"

# Процессоры
		CPUCount=$(echo "${dmd}"|grep -c "^Processor Information")
		ptr=0
		for i in $(seq 1 ${CPUCount}) ; do
			ptr=$(( $(echo "${dmd}" | tail -n +$(($ptr+1)) |grep  -m 1 -n "^Processor Information" | cut -d ':' -f 1) + ${ptr} ))
			DMICPUSocketDesignation=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Socket Designation:"|cut -d ':' -f 2)
			CPUManufacturer[$DMICPUSocketDesignation]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Manufacturer"|cut -d ':' -f 2)
			CPUVersion[$DMICPUSocketDesignation]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Version:"|cut -d ':' -f 2)
			log 1 "${hst} CPU $DMICPUSocketDesignation == ${CPUManufacturer[$DMICPUSocketDesignation]} ${CPUVersion[$DMICPUSocketDesignation]}"
		done

# Память
		RAMCount=$(echo "${dmd}"|grep -c "^Memory Device$")
		ptr=0
		idx=0
		for i in $(seq 1 ${RAMCount}) ; do
			idx=$(($idx + 1))
			ptr=$(( $(echo "${dmd}" | tail -n +$(($ptr + 1)) |grep  -m 1 -n "^Memory Device$" | cut -d ':' -f 1) + ${ptr} ))
			DMIMEMSize[$idx]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Size:"|cut -d ':' -f 2)
			DMIMEMLocator[$idx]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Locator:"|cut -d ':' -f 2)
			DMIMEMManufacturer[$idx]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Manufacturer:"|cut -d ':' -f 2)
			DMIMEMPartNumber[$idx]=$(echo "${dmd}"|tail -n +${ptr}|grep -m1 "Part Number:"|cut -d ':' -f 2)
			log 1 "${hst} RAM ${DMIMEMLocator[$idx]} == ${DMIMEMSize[$idx]} ${DMIMEMManufacturer[$idx]} ${DMIMEMPartNumber[$idx]}"
		done

# BlockDevices
		while read -r i ; do
			BLKName=$(echo $i |cut -d '|' -f 1|cut -d '=' -f 2)
			if [[ ! -z "${BLKName}" ]] ; then
				BLKSizetmp=$(echo $i |cut -d '|' -f 2|cut -d '=' -f 2)
				BLKSizetmp=$(($BLKSizetmp + 0))
				BLKSize[$BLKName]="$(( $BLKSizetmp / 1000 / 1000 / 1000 )) Gb"
				BLKModel[$BLKName]=$(echo $i |cut -d '|' -f 3|cut -d '=' -f 2)
				BLKSerial[$BLKName]=$(echo $i |cut -d '|' -f 4|cut -d '=' -f 2)
				BLKVendor[$BLKName]=$(echo ${BLKModel[$BLKName]} |cut -d ' ' -f 1)
				test "${BLKModel[$BLKName]}" == "${BLKVendor[$BLKName]}" && BLKVendor[$BLKName]=""
				log 1 "${hst} BLK $BLKName == ${BLKVendor[$BLKName]} ${BLKModel[$BLKName]} ${BLKSerial[$BLKName]} ${BLKSize[$BLKName]}"
			else
				log 1 "${hst} BLKName is empty on line '$i'"
			fi
		done <<< $(echo "${blk}")

# SMART
		SMTCount=$(echo "${smt}"|grep -c "^%%SMT-")
		ptr=0
		for i in $(seq 1 ${SMTCount}) ; do
			ptr=$(( $(echo "${smt}" | tail -n +$(($ptr+1)) |grep  -m 1 -n "^%%SMT-" | cut -d ':' -f 1) + ${ptr} ))
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
			log 1 "${hst} SMT $SMTName == ${SMTVendor[$SMTName]} ${SMTModel[$SMTName]} ${SMTSerial[$SMTName]}"
		done

# Виртуалки
		VDSCount=$(echo "${vds}"|grep -c "^Domain: ")
		ptr=0
			for i in $(seq 1 ${VDSCount}) ; do
			ptr=$(( $(echo "${vds}" | tail -n +$(( $ptr + 1 )) |grep  -m 1 -n "^Domain:" | cut -d ':' -f 1) + ${ptr} ))
			VDSName=$(echo "${vds}"|tail -n +${ptr} |grep  -m 1 "^Domain:"|tr -d " '"|cut -d ':' -f 2)
			if [[ ${i} -eq ${VDSCount} ]] ; then
				 VDSDomInfo=$(echo "${vds}\n\n\n"|tail -n +$(( ${ptr} + 1 )) |head -n -1)
			else
				 VDSDomInfo=$(echo "${vds}"|tail -n +$(( ${ptr} + 1 )) |grep -B 999 -m1 "^Domain:"|head -n -1)
			fi
			VDSState[$VDSName]=$(echo "${VDSDomInfo}"|grep -m1 "state.state="|cut -d '=' -f 2)
			VDSMemory[$VDSName]=$(echo "${VDSDomInfo}"|grep -m1 "balloon.maximum="|cut -d '=' -f 2)
			VDSVCPU[$VDSName]=$(echo "${VDSDomInfo}"|grep -m1 "vcpu.current="|cut -d '=' -f 2)
			test "${VDSState[$VDSName]}" == "5" && VDSState[$VDSName]="offline" || VDSState[$VDSName]="active"
			VDSMemory[$VDSName]=$(( ${VDSMemory[$VDSName]} / 1024 ))
			log 1 "${hst} VM $VDSName == State=${VDSState[$VDSName]} MEM=${VDSMemory[$VDSName]} CPU=${VDSVCPU[$VDSName]}"

			VDSBLKCount=$(echo "${VDSDomInfo}"|grep -m1 "block.count="|cut -d '=' -f 2)
			VDSBLKTotalsize[$VDSName]=0
			for i in $(seq 1 ${VDSBLKCount}) ; do
				VDSBLKName=$(echo "${VDSDomInfo}"|grep -m1 "block\.$(($i - 1))\.name="|cut -d '=' -f 2)
				VDSBLKPath=$(echo "${VDSDomInfo}"|grep -m1 "block\.$(($i - 1))\.path="|cut -d '=' -f 2)
				VDSBLKSize=$( expr $(echo "${VDSDomInfo}"|grep -m1 "block\.$(($i - 1))\.physical="|cut -d '=' -f 2) + 0 )
				VDSBLKSize=$(( $VDSBLKSize / 1024 / 1024 / 1024 ))
				if [[ ${VDSBLKSize} -gt 0 && "${VDSBLKPath}" != "" ]] ; then
					VDSBLKData[$VDSName]="| ${VDSBLKName} | ${VDSBLKSize} | ${VDSBLKPath} |\r\n${VDSBLKData[$VDSName]}"
					VDSBLKTotalsize[$VDSName]=$(( ${VDSBLKTotalsize[$VDSName]} + $VDSBLKSize ))
					log 1 "${hst} VM_BLK $VDSBLKName == $VDSBLKPath $VDSBLKSize"
				fi
			done
			VDSBLKData[$VDSName]="#### NBImport Block Devices\r\n| Name | Size(GB) | Path |\r\n| --- | --- | --- |\r\n${VDSBLKData[$VDSName]}\r\n"
		done

# Исправляем SCSI модели и серийные номера, которые ограничены в 16 байт
		for i in "${!BLKSize[@]}" ; do
			if [[ -z "${BLKModel[$i]}" ]] ; then
				 BLKModel[$i]=${SMTModel[$i]}
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
			BLKSerial[$i]=${BLKSerial[$i]:0:48}
			BLKVendor[$i]=${SMTVendor[$i]}
		done
	else
		log 1 "${hst} is VM"
	fi
# Общий блок для гипервизоров и вируальных машин
# Сеть	
	IFCount=$(echo "${ipa}"|grep -c "^[[:digit:]]*:")
	ptr=0
	for i in $(seq 1 ${IFCount}) ; do
		ptr=$(( $(echo "${ipa}" | tail -n +$(($ptr+1)) |grep  -m 1 -n "^[[:digit:]]*: " | cut -d ':' -f 1) + ${ptr} ))
		IFName=$(echo "${ipa}"|tail -n +${ptr}|grep -m1 "^[[:digit:]]*: "|cut -d ' ' -f 2|cut -d ':' -f 1)
		IFState[$IFName]=$(echo "${ipa}"|tail -n +${ptr}|grep -o -m1 "state [[:alpha:]]* " |cut -d ' ' -f 2)
		IFMtu[$IFName]=$(echo "${ipa}"|tail -n +${ptr}|grep -o -m1 "mtu [[:digit:]]* " |cut -d ' ' -f 2)
		if [[ ${i} -eq ${IFCount} ]] ; then
			IFBlock=$(echo -e "${ipa}\n\n\n"|tail -n +$(( ${ptr} + 1 )) |head -n -1)
		else
			IFBlock=$(echo "${ipa}"|tail -n +$(( ${ptr} + 1 )) |grep -B 999 -m1 "^[[:digit:]]*: "|head -n -1)
		fi
		IFMac[$IFName]=$(echo "${IFBlock}"|grep -o -m 1 "link\/[[:alpha:]]* [0-9a-f\:]*" | cut -d ' ' -f 2)
		if [[ $(echo "${IFBlock}"|grep " mii_status ") ]] ; then
			IFType[$IFName]="1000base-t"
		elif [[ "${IFName}" =~ ^(eth|eno|enp|ens|p|P)[0-9] ]] ; then
			IFType[$IFName]="1000base-t"
		else
			IFType[$IFName]="virtual"
		fi
		IFIPs[$IFName]=$(echo "${IFBlock}"|grep -o "inet [0-9\./]*" | cut -d ' ' -f 2 | tr -s '\n' ' ')
		log 1 "${hst} IFIP $IFName == ${IFState[$IFName]} ${IFMtu[$IFName]} ${IFMac[$IFName]} ${IFType[$IFName]} ${IFIPs[$IFName]}"
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

	if [[ -z "${hyp}" ]] ; then
# Ищем устройсвто по серийному номеру и по имени
		curl_get "dcim/devices/?serial=${DMI['SYSSerialNumber']}"
		log 1 "${hst} ${CurlStatus}"
		jdevice="${CurlOut}"
		if [[ $(echo "$jdevice"|${J} .count) -eq 1 ]] ; then
			device_id=$(echo "$jdevice"|${J} .results[0].id)
		else
			curl_get "dcim/devices/?name=${hst}"
			log 1 "${hst} ${CurlStatus}"
			jdevice="${CurlOut}"
			if [[ $(echo "$jdevice"|${J} .count) -eq 1 ]] ; then
				device_id=$(echo "$jdevice"|${J} .results[0].id)
			else
				log 4 "${hst} Device not found for ${hst} (sn:${DMI['SYSSerialNumber']})"
				break
			fi
		fi
		jdevice=$(echo "$jdevice"|${J} .results[0])
# Имя
		t=$(echo "$jdevice"|${J} .name)
		if [[ "${t//\"/}" != "${hst}" ]] ; then
			log 3 "${hst} Change name ${t//\"/} -> $hst"
			curl_patch "dcim/devices/${device_id}/" "{'name':'${hst}'}"
			log 1 "${hst} ${CurlStatus}"
		fi
# серийный номер
		t=$(echo "$jdevice"|${J} .serial)
		if [[ -z "$t" ]] ; then
			if [[ "${t//\"/}" != "${DMI['SYSSerialNumber']}" ]] ; then
				log 3 "${hst} Change serial ${t//\"/} -> ${DMI['SYSSerialNumber']}"
				curl_patch "dcim/devices/${device_id}/" "{'serial':'${DMI['SYSSerialNumber']}'}"
				log 1 "${hst} ${CurlStatus}"
			fi
		fi
# Виртуальные машины
		if [[ ${#VDSState[@]} -gt 0 ]] ; then
			curl_get "dcim/devices/${device_id}/"
			log 1 "${hst} ${CurlStatus}"
			jcluster_id=$(echo "${CurlOut}"|${J} .cluster.id)
			if [[ "${jcluster_id}" == "null" || "${jcluster_id}" == "" ]] ; then
				log 1 "${hst} Can't find attached cluster"
				log 1 "${hst} ${CurlStatus}"
				curl_get "virtualization/clusters/?name=${hst}"
				jcluster_id=$(echo "${CurlOut}"|grep "\"device_count\":0"|${J} .results[0].id)
				if [[ "${jcluster_id}" == "null" || "${jcluster_id}" == "" ]] ; then
					log 1 "${hst} Can't find cluster by name ${hst}"
				else
					log 3 "${hst} Joining cluster ${jcluster_id} (found by name)"
					curl_patch "dcim/devices/${device_id}/" "{'cluster':${jcluster_id}}"
					log 1 "${hst} ${CurlStatus}"
				fi
			fi
			if [[ "${jcluster_id}" == "null" || "${jcluster_id}" == "" ]] ; then
				log 2 "${hst} Create cluster ${hst}"
				curl_post "virtualization/clusters/" "{'name':'${hst}','type':'1','tags':[${TAG_ID}]}"
				log 1 "${hst} ${CurlStatus}"
				curl_get "virtualization/clusters/?name=${hst}"
				jcluster_id=$(echo "${CurlOut}"|${J} .results[0].id)
				if [[ "${jcluster_id}" == "null" || "${jcluster_id}" == "" ]] ; then
					log 4 "${hst} Can't find or create new cluser_id"
					break
				fi
			fi
			log 1 "${hst} Cluster id = ${jcluster_id}"
			curl_get "virtualization/virtual-machines/?cluster_id=${jcluster_id}&limit=0"
			log 1 "${hst} ${CurlStatus}"
			jvms=$(echo "${CurlOut}"|${J} ".results[]" -c)
			for vm in ${!VDSState[@]} ; do
				curl_get "virtualization/virtual-machines/?name=${vm}"
				log 1 "${hst} ${CurlStatus}"
				jvm_by_name="${CurlOut}"
				jvm_by_name_count=$(echo "${CurlOut}"|${J} ".count" -r)
				jvm_by_name_count=$(($jvm_by_name_count + 0))
				if [[ ${jvm_by_name_count} -gt 1 ]] ; then
					log 4 "${hst} DUPLICATE VM $vm"
					continue
				fi
				jvm=$(echo "${jvms}"|grep "name\":\"${vm}\"")
				jvms=$(echo "${jvms}"|grep -v "name\":\"${vm}\"")
				vm_action="ignore"
				vm_post_data=""
				vm_old_cluster=""
				if [[ -z "${jvm}" ]] ; then
					jvm=$(echo "${jvm_by_name}"|${J} ".results[0]" -c |grep  "name\":\"${vm}\"")
					if [[ "${VDSState[$vm]}" == "active" && "${jvm}" == "" ]] ; then
						vm_action="create"
					fi
					if [[ "${VDSState[$vm]}" == "active" && "${jvm}" != "" ]] ; then
						vm_action="edit"
						vm_post_data=",'cluster':'${jcluster_id}'"
						vm_old_cluster="${jvm}"
					fi
					if [[ "${VDSState[$vm]}" != "active" && "${jvm}" == "" ]] ; then
						vm_action="create"
					fi
				else
					vm_action="edit"
				fi

				if [[ "${vm_action}" != "ignore" ]] ; then
					if [[ "${jvm}" != *"vcpus\":${VDSVCPU[$vm]}"* ]] ; then vm_post_data="${vm_post_data},'vcpus':${VDSVCPU[$vm]}" ; fi
					if [[ "${jvm}" != *"memory\":${VDSMemory[$vm]}"* ]] ; then vm_post_data="${vm_post_data},'memory':'${VDSMemory[$vm]}'" ; fi
					if [[ "${jvm}" != *"disk\":${VDSBLKTotalsize[$vm]}"* ]] ; then vm_post_data="${vm_post_data},'disk':${VDSBLKTotalsize[$vm]}" ; fi
					if [[ "${jvm}" != *"status\":{\"value\":\"${VDSState[$vm]}"* ]] ; then vm_post_data="${vm_post_data},'status':'${VDSState[$vm]}'" ; fi

# часть с информацией от nbimport
					jvm_blkcomment=$(echo "$jvm" | ${J} .comments|sed -e 's/^"//' -e 's/"$//' -e 's/end-of-nbimport.*$//g')
					if [[ "${jvm_blkcomment}" != "${VDSBLKData[$vm]}" ]] ; then
# часть с информацией от пользователя
						jvm_comment=$(echo "$jvm" | ${J} .comments|sed -e 's/^"//' -e 's/"$//' -e 's/^.*end-of-nbimport\\r\\n\*\*\*\\r\\n//g')
						test -z "${jvm_comment}" && jvm_comment="place comment here"
						vm_post_data="${vm_post_data},'comments':'${VDSBLKData[$vm]}end-of-nbimport\r\n***\r\n${jvm_comment}'"
						log 1 "${hst} User Comment $jvm_comment"
					fi

					if [[ "${vm_post_data}" != "" ]] ; then
						if [[ "${vm_action}" == "create" ]] ; then
							log 3 "${hst} Create VM $vm - ${vm_post_data:0:80}..."
							curl_post "virtualization/virtual-machines/" "{ 'tags':[${TAG_ID}] ${vm_post_data},'name':'${vm}','cluster':'${jcluster_id}' }"
							log 1 "${hst} ${CurlStatus}"
						elif [[ "${vm_action}" == "edit" ]] ; then
							if [[ "${vm_old_cluster}" == "" ]] ; then
								jvm_id=$(echo "$jvm" | ${J} .id)
								log 3 "${hst} Edit VM $vm($jvm_id) - ${vm_post_data:0:80}..."
								curl_patch "virtualization/virtual-machines/${jvm_id}/" "{ 'tags':[${TAG_ID}] ${vm_post_data} }"
								log 1 "${hst} ${CurlStatus}"
							else
								jvm_id=$(echo "$jvm" | ${J} .id)
								vm_old_cluster_name=$(echo "${vm_old_cluster}"|${J} -r .cluster.name)
								vm_old_cluster_id=$(echo "${vm_old_cluster}"|${J} -r .cluster.id)
								log 1 "${hst} ${vm_old_cluster_name} ${vm_old_cluster}"
								log 3 "${hst} Move and Edit VM $vm($jvm_id) from ${vm_old_cluster_name}(${vm_old_cluster_id})"
								curl_patch "virtualization/virtual-machines/${jvm_id}/" "{ 'tags':[${TAG_ID}] ${vm_post_data} }"
								log 1 "${hst} ${CurlStatus}"
							fi
						fi
					else
						log 1 "${hst} VM ${vm} unchanged"
					fi
				else
					log 1 "${hst} VM ${vm} ignored"
				fi
			done
			for lostvm in $(echo "${jvms}" | ${J} .name | tr -d '"') ; do
				jvm=$(echo "${jvms}"|grep "name\":\"${lostvm}\"")
				if [[ "${jvm}" == *"status\":{\"value\":\"active\""* ]] ; then
					jvm_id=$(echo "$jvm" | ${J} .id)
					log 3 "${hst} Unknown or Lost VM ${lostvm}(${jvm_id}). Set status to 'Offline'"
					curl_patch "virtualization/virtual-machines/${jvm_id}/" "{ 'status':'offline' }"
					log 1 "${hst} ${CurlStatus}"
				fi
			done
		fi
# Инвентори
		log 1 "${hst} Inventory sync"
		curl_get "dcim/inventory-items/?device_id=${device_id}&discovered=true&limit=0"
		log 1 "${hst} ${CurlStatus}"
		jinventory=$(echo "${CurlOut}"|${J} '.results[]' -c)
		jinventory_ids=$(echo "${CurlOut}"|${J} .'results[].id' | tr -d '"')
# Материнская плата
		jbaseboard=$(echo "${jinventory}" |grep  "name\":\"Base Board Information\"")
		if [[ -z "${jbaseboard}" ]] ; then
			log 3 "${hst} Create inventory BaseBoard ${DMI['BRDManufacturer']} ${DMI['BRDProductName']} ${DMI['BRDSerialNumber']}"
			curl_post "dcim/inventory-items/" "{ 'device':'${device_id}','name':'Base Board Information','manufacturer':'$(mfr_id "${DMI['BRDManufacturer']}")','part_id':'${DMI['BRDProductName']}','serial':'${DMI['BRDSerialNumber']}','discovered':'true','tags':[${TAG_ID}] }"
			log 1 "${hst} ${CurlStatus}"
		else
			jinventory_ids=$(echo "${jinventory_ids}"|grep -v ^$(echo ${jbaseboard}|${J} .id))
			log 1 "${hst} inventory Base Board already exists"
		fi
# Процессоры
		log 1 "${hst} CPU"
		for i in "${!CPUManufacturer[@]}" ; do
			post_data="{ 'device':'${device_id}','name':'${i}','manufacturer':'$(mfr_id "${CPUManufacturer[$i]}")','part_id':'${CPUVersion[$i]}','discovered':'true','tags':[${TAG_ID}] }"
			for j in $(echo "${jinventory}"|grep  "name\":\"${i}\""|${J} .id) ; do
				if [[ -z "${post_data}" ]] ; then
					log 3 "${hst} Delete duplicate inventory with name=${i} and id=${j}"
					curl_delete "dcim/inventory-items/${j}"
					log 1 "${hst} ${CurlStatus}"
				else
					jcpu=$(echo "${jinventory}" |grep  -m 1 "name\":\"${i}\""|sed -e 's/[^a-zA-Z0-9":,{}_]//g')
					dmicpu=$(echo "${CPUVersion[$i]}"|sed -e 's/[^a-zA-Z0-9":,{}_]//g')
					if [[ ! $(echo " ${jcpu} " | grep "part_id\":\"${dmicpu}\"" ) ]] ; then
						log 3 "${hst} Change inventory ${post_data:0:50}..."
						curl_patch "dcim/inventory-items/${j}/" "${post_data}"
						log 1 "${hst} ${CurlStatus}"
					fi
					post_data=""
				fi
				jinventory_ids=$(echo "${jinventory_ids}"|grep -v ^${j})
			done
			if [[ ! -z "${post_data}" ]] ; then
				log 3 "${hst} Create inventory ${post_data:0:50}..."
				curl_post "dcim/inventory-items/" "${post_data}"
				log 1 "${hst} ${CurlStatus}"
			fi
		done
# Память
		log 1 "${hst} RAM"
		for i in "${!DMIMEMLocator[@]}" ; do
			post_data="{'device':'$device_id','name':'${DMIMEMLocator[$i]}','manufacturer':'$(mfr_id "${DMIMEMManufacturer[$i]}")','part_id':'${DMIMEMPartNumber[$i]}','description':'${DMIMEMSize[$i]}','discovered':'true','tags':[${TAG_ID}] }"
			for j in $(echo "${jinventory}"|grep  "name\":\"${DMIMEMLocator[$i]}\""|${J} .id) ; do
				if [[ -z "${post_data}" ]] ; then
					log 3 "${hst} Delete duplicate inventory with name=${i} and id=${j}"
					curl_delete "dcim/inventory-items/${j}"
					log 1 "${hst} ${CurlStatus}"
				else
					jmem=$(echo "${jinventory}" |grep  -m 1 "name\":\"${DMIMEMLocator[$i]}\""|sed -e 's/[^a-zA-Z0-9":,{}_]//g')
					dmimempart=$(echo "${DMIMEMPartNumber[$i]}"|sed -e 's/[^a-zA-Z0-9":,{}_]//g')
					dmimemdesc=$(echo "${DMIMEMSize[$i]}"|sed -e 's/[^a-zA-Z0-9":,{}_]//g')
					if [[ ! $(echo " ${jmem} " | grep "part_id\":\"${dmimempart}\"" ) || ! $(echo " ${jmem} " | grep "description\":\"${dmimemdesc}\"" ) ]] ; then
						log 3 "${hst} Change inventory ${post_data:0:50}..."
						curl_patch "dcim/inventory-items/${j}/" "${post_data}"
						log 1 "${hst} ${CurlStatus}"
					fi
					post_data=""
				fi
				jinventory_ids=$(echo "${jinventory_ids}"|grep -v ^${j})
			done
			if [[ ! -z "${post_data}" ]] ; then
				log 3 "${hst} Create inventory ${post_data:0:50}..."
				curl_post "dcim/inventory-items/" "${post_data}"
				log 1 "${hst} ${CurlStatus}"
			fi
		done
# BlockDevices
		log 1 "${hst} BLK"
		for i in "${!BLKSize[@]}" ; do
			post_data="{'device':'$device_id','name':'${i}','manufacturer':'$(mfr_id "${BLKVendor[$i]}")','part_id':'${BLKModel[$i]}','description':'${BLKSize[$i]}','serial':'${BLKSerial[$i]}','discovered':'true','tags':[${TAG_ID}] }"
			for j in $(echo "${jinventory}"|grep  "name\":\"${i}\""|${J} .id) ; do
				if [[ -z "${post_data}" ]] ; then
					log 3 "${hst} Delete duplicate inventory with name=${i} and id=${j}"
					curl_delete "dcim/inventory-items/${j}"
					log 1 "${hst} ${CurlStatus}"
				else
					jblk=$(echo "${jinventory}" |grep  -m 1 "name\":\"${i}\""|sed -e 's/[^a-zA-Z0-9":,{}_]//g')
					dmiblkpart=$(echo "${BLKModel[$i]}"|sed -e 's/[^a-zA-Z0-9":,{}_]//g')
					dmiblkdesc=$(echo "${BLKSize[$i]}"|sed -e 's/[^a-zA-Z0-9":,{}_]//g')
					dmiblkser=$(echo "${BLKSerial[$i]}"|sed -e 's/[^a-zA-Z0-9":,{}_]//g')
					if [[ ! $(echo " ${jblk} " | grep "part_id\":\"${dmiblkpart}\"" ) || ! $(echo " ${jblk} " | grep "description\":\"${dmiblkdesc}\"") || ! $(echo " ${jblk} " | grep "serial\":\"${dmiblkser}\"") ]] ; then
						log 3 "${hst} Change inventory ${post_data:0:50}..."
						curl_patch "dcim/inventory-items/${j}/" "${post_data}"
						log 1 "${hst} ${CurlStatus}"
					fi
					post_data=""
				fi
				jinventory_ids=$(echo "${jinventory_ids}"|grep -v ^${j})
			done
			if [[ ! -z "${post_data}" ]] ; then
				log 3 "${hst} Create inventory ${post_data:0:50}..."
				curl_post "dcim/inventory-items/" "${post_data}"
				log 1 "${hst} ${CurlStatus}"
			fi
		done

# Предупреждаем о лишних
		log 1 "${hst} Orphaned inventory"
		for i in $jinventory_ids ; do
			name=$(echo "${jinventory}"|grep "id\":${i}"|${J} '.name')
			part_id=$(echo "${jinventory}"|grep "id\":${i}"|${J} '.part_id')
			discovered=$(echo "${jinventory}"|grep "id\":${i}"|${J} '.discovered')
			if [[ "${discovered}" == "true" ]] ; then
				log 4 "${hst} Delete missing discovered inventory ${name} ${part_id}"
				log 1 "${hst} Delete inventory json=$(echo "${jinventory}"|grep "id\":${i}")"
				curl_delete "dcim/inventory-items/${i}"
				log 1 "${hst} ${CurlStatus}"
			fi
		done
	else
# Блок обработки вирутальных машин
		curl_get "virtualization/virtual-machines/?name=${hst}&limit=0"
		log 1 "${hst} ${CurlStatus}"
		vmhost=$(echo "${CurlOut}"|${J} .results[0] -c|grep "name\":\"${hst}\"")

		if [[ -z "${vmhost}" ]] ; then
			log 4 "${hst} Virtual Machine ${hst} not found. Sync your hypervisor first."
		else
			vmhost_id=$(echo "${vmhost}" | ${J} .id)
			log 1 "${hst} VM host id = $vmhost_id"
		fi
	fi

# Еще один общий блок для гипервизоров и вируальных машин
# Интерфейсы
	if [[ -z "${vmhost_id}" ]] ; then
		curl_get "dcim/interfaces/?device_id=${device_id}&limit=0"
		log 1 "${hst} ${CurlStatus}"
		jiface="${CurlOut}"
		curl_get "dcim/interfaces/?device_id=${device_id}&enabled=false&limit=0"
		log 1 "${hst} ${CurlStatus}"
		jiface_disabled="${CurlOut}"
	else
		curl_get "virtualization/interfaces/?virtual_machine_id=${vmhost_id}"
		log 1 "${hst} ${CurlStatus}"
		jiface="${CurlOut}"
		curl_get "virtualization/interfaces/?virtual_machine_id=${vmhost_id}&enabled=false&limit=0"
		log 1 "${hst} ${CurlStatus}"
		jiface_disabled="${CurlOut}"
	fi
	if [[ -z "${jiface}" ]] ; then
		jiface_names=""
	else
		jiface_names=$(echo "${jiface}" | ${J} '.results[].name' -r |tr -s '\n' ' ')
		jiface_names_disabled=$(echo "${jiface_disabled}" | ${J} '.results[].name' -r |tr -s '\n' ' ')
		jiface_names="${jiface_names} ${jiface_names_disabled}"

	fi
	log 1 "${hst} Found interfaces from netbox ${jiface_names}"
	for i in "${!IFState[@]}" ; do
		if [[ "${i}" =~ ^(eth|eno|enp|ens|br|p|P)[0-9][0-9]*[sfduci0-9]* ]] ; then
			if [[ ! $(echo " ${jiface_names} " | grep "${i}" ) ]] ; then
				log 3 "Create interface $i - mtu ${IFMtu[$i]} mac ${IFMac[$i]} type ${IFType[$i]}" 
				if [[ -z "${vmhost_id}" ]] ; then 
					curl_post "dcim/interfaces/" "{ 'device':'${device_id}','name':'${i}','type':'${IFType[$i]}','mac_address':'${IFMac[$i]}','mtu':'${IFMtu[$i]}','tags':[${TAG_ID}] }"
					log 1 "${hst} ${CurlStatus}"
				else
					curl_post "virtualization/interfaces/" "{ 'virtual_machine':'${vmhost_id}','name':'${i}','mac_address':'${IFMac[$i]}','mtu':'${IFMtu[$i]}','tags':[${TAG_ID}] }"
					log 1 "${hst} ${CurlStatus}"
				fi
			fi
		fi
	done

# ip адреса
	if [[ -z "${vmhost_id}" ]] ; then 
		curl_get "dcim/interfaces/?device_id=${device_id}&limit=0"
		log 1 "${hst} ${CurlStatus}"
		jiface="${CurlOut}"
	else
		curl_get "virtualization/interfaces/?virtual_machine_id=${vmhost_id}&limit=0"
		log 1 "${hst} ${CurlStatus}"
		jiface="${CurlOut}"
	fi
	if [[ -z "${vmhost_id}" ]] ; then 
		curl_get "ipam/ip-addresses/?device_id=${device_id}&limit=0"
		log 1 "${hst} ${CurlStatus}"
		jips="${CurlOut}"
	else
		curl_get "ipam/ip-addresses/?virtual_machine_id=${vmhost_id}&limit=0"
		log 1 "${hst} ${CurlStatus}"
		jips="${CurlOut}"
	fi
	jips_string=$(echo -e "$jips" | ${J} .results[].address|tr -d '"'|tr -s '\n' ' ')
	log 1 "${hst} Found ip addresses from netbox ${jips_string}"

	for i in "${!IFState[@]}" ; do
		if [[ "${i}" =~ ^(eth|eno|enp|ens|br|p|P)[0-9][0-9]*[sfduci0-9]* ]] ; then
			if [[ ! -z "${IFIPs[$i]}" ]] ; then
				for ip in ${IFIPs[$i]} ; do
					if [[ ! $(echo " ${jips_string} " | grep "${ip}" ) ]] ; then
						jiface_id=$(echo "${jiface}"| ${J} ."results[]|select(.name == \"$i\").id")
						if [[ "${jiface_id}" == "null" || "${jiface_id}" == "" ]] ; then
							log 4 "${hst}: Can't find interface_id for ${i}"
						else
							log 3 "${hst} Create ip ${ip} - on ${i} (${jiface_id})"
							if [[ -z "${vmhost_id}" ]] ; then
								curl_post "ipam/ip-addresses/" "{ 'address':'${ip}','family':'4','status':'active','assigned_object_type':'dcim.interface','assigned_object_id':'${jiface_id}','tags':[${TAG_ID}] }"
								log 1 "${hst} ${CurlStatus}"
							else
								curl_post "ipam/ip-addresses/" "{ 'address':'${ip}','family':'4','status':'active','assigned_object_type':'virtualization.vminterface','assigned_object_id':'${jiface_id}','tags':[${TAG_ID}] }" 
								log 1 "${hst} ${CurlStatus}"
							fi
						fi
					else
						log 1 "${hst} Skip interface=${i}, ip=${ip}"
					fi
				done
			fi
		fi
	done
	mv ${hostinfofile} ${HOSTINFO_READY_DIR}
	log 2 "${hst} ($(basename ${hostinfofile})) ready!"
done

