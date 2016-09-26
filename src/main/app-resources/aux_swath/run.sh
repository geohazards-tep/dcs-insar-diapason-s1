#!/bin/bash

#source the ciop functions
source ${ciop_job_include}

#source some utility functions
source $_CIOP_APPLICATION_PATH/lib/util.sh 


#read polarization to process
export pol=`ciop-getparam pol`

if [ -z "${pol}" ]; then
    export pol="VV"
fi 


function trapFunction()
{
    procCleanup
    ciop-log "ERROR : Signal was trapped"
    exit
}


function extract_safe() {
  safe_archive=${1}
  optional=${2}
  safe=$( unzip -l ${safe_archive} | grep "SAFE" | grep -v zip | head -n 1 | awk '{ print $4 }' | xargs -I {} basename {} )

  [ -n "${optional}" ] && safe=${optional}/${safe}
  mkdir -p ${safe}
  
  local annotlist=""
  local measurlist=""
  
  if [ -n "${pol}" ]; then
      annotlist=$( unzip -l "${safe_archive}" | grep annotation | grep .xml | grep -v calibration | awk '{ print $4 }' | grep -i "\-${pol}\-")
      measurlist=$( unzip -l "${safe_archive}" | grep measurement | grep .tiff | awk '{ print $4 }'  | grep -i "\-${pol}\-")
  else
      annotlist=$( unzip -l "${safe_archive}" | grep annotation | grep .xml | grep -v calibration | awk '{ print $4 }' )
      measurlist=$( unzip -l "${safe_archive}" | grep measurement | grep .tiff | awk '{ print $4 }' )
  fi

  for annotation in $annotlist
  do
     unzip -o -j ${safe_archive} "${annotation}" -d "${safe}/annotation" 1>&2
     res=$?
     [ "${res}" != "0" ] && return ${res}
  done
  ciop-log "INFO" "Unzipped $( ls -l ${safe}/annotation )"
  for measurement in $measurlist
  do
    unzip -o -j ${safe_archive} "${measurement}" -d "${safe}/measurement" 1>&2
    res=$?
    [ "${res}" != "0" ] && return ${res}    
  done
  echo ${safe}
  
}



function get_POEORB() {
  local S1_ref=$1
  local aux_dest=$2

  [ -z "${aux_dest}" ] && aux_dest="." 

  local startdate
  local enddate
  
  startdate="$( opensearch-client "${S1_ref}" startdate)" 
  enddate="$( opensearch-client "${S1_ref}" enddate)" 
  
  aux_list=$( opensearch-client  "http://data.terradue.com/gs/catalogue/aux/gtfeature/search?q=AUX_POERB&start=${startdate}&stop=${enddate}" enclosure )

  [ -z "${aux_list}" ] && return 1

  echo ${aux_list} | ciop-copy -o ${aux_dest} -

}

function main(){
  masterref=$( echo "${1}" | sed 's:[;@]: :g' | awk '{print $1}' )
  [ -z "${masterref}" ] && return ${ERR_MASTER}

  slaveref=$( echo "${1}" |  sed 's:[;@]: :g' | awk '{print $2}' )
  [ -z "${slaveref}" ] && return ${ERR_SLAVE}
  
  local datadir="${serverdir}"
  [ -z "${datadir}" ] && {
      datadir="${TMPDIR}"
}
  #make sure the master and slave image intesect !
  product_intersect "${masterref}" "${slaveref}" || {
      ciop-log "ERROR : slave and master image do not intersect"
      exit ${ERRINVALID}
  }
  
  
  ciop-log "INFO" "Getting Master"
  ciop-log "INFO" "Master ref : ${masterref}"
  
  master=$( get_data ${masterref} ${datadir}/download/master )
  res=$?
  [ "${res}" != "0" ] && {
      ciop-log "ERROR" "Failed to download ${masterref}"
      return ${res}
      }
  ciop-log "INFO" "local master is ${master}"
  

  ciop-log "INFO" "Getting Slave"
  ciop-log "INFO" "Slave ref : ${slaveref}"
  slave=$( get_data ${slaveref} ${datadir}/download/slave )
  res=$?
  [ "${res}" != "0" ] && { 
      ciop-log "ERROR" "Failed to download ${slaveref}"
      return ${res}
}
  ciop-log "INFO" "local slave is ${slave}"

  #master input check
  product_check "${master}" || {
    status=$?
    ciop-log "ERROR : invalid  master input"
    exit $status
}

  #slave input check
  product_check "${slave}" || {
    status=$?
    ciop-log "ERROR : invalid slave input"
    exit $status
}
  
  masterinfo=($(product_name_parse "${master}"))
  slaveinfo=($(product_name_parse "${slave}"))

#make sure master and slave modes match (IW and IW , or EW and EW)
  if [ "${masterinfo[1]}"  !=  "${slaveinfo[1]}" ]; then
      ciop-log "ERROR : slave and master image are from different modes"
      exit ${ERRINVALID}
fi



mode="${masterinfo[1]}"
nswaths=0
case $mode in
    IW)nswaths=3;;
    EW)nswaths=5;;
    *)nswaths=0;;
esac

if [ $nswaths -eq 0 ]; then
    ciop-log "ERROR : master image invalid mode ${mode}"
    exit ${ERRINVALID}
fi



  ciop-log "INFO" "Extracting master"
  master_safe=$( extract_safe ${master} ${datadir}/data/master )
  [ "$?" != "0" ] && return ${ERR_EXTRACT}

  ciop-log "INFO" "Extracting slave"
  slave_safe=$( extract_safe ${slave} ${datadir}/data/slave )
  [ "$?" != "0" ] && return $ERR_EXTRACT

  refmaster=`basename ${master_safe}`
  refslave=`basename ${slave_safe}`

#pass inputs as well as swath number to next node
for swath in `seq 1 ${nswaths}`; do
    echo "$refmaster@${swath}@$refslave@${swath}@$pol" | ciop-publish -s
done

#stage-out the results
ciop-publish "${master_safe}" -r -a || return $?
ciop-publish "${slave_safe}" -r -a || return $?


}

trap trapFunction SIGHUP SIGINT SIGTERM


# loop through the pairs
while read master
do
    ciop-log "INFO" "source : $master"
    slave=`ciop-getparam slave`
    ciop-log "INFO" "param : $slave"
    pair="${master};${slave}"
    export serverdir=${TMPDIR}/$( uuidgen )
    mkdir -p ${serverdir}/download/master
    mkdir -p ${serverdir}/download/slave
    main ${pair}
    [ "${res}" != "0" ] && {
	procCleanup
	exit ${res}
    }
    procCleanup
    exit ${SUCCESS}
done

