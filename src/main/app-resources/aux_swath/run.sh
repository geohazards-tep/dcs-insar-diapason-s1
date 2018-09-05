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

  if [ -d "${safe_archive}" ]; then
      local safedir=`find ${safe_archive} -type d -name "*.SAFE" -exec readlink -f '{}' \; | tail -1`
      [ -n "${safedir}" ] && {
	  #remove files from unneeded polarisations
	  if [ -n "$pol" ]; then
	      for file in `find "${safedir}" -type f -iname "*s1[ab]*.xml" -print -o -iname "*s1[ab]*.tiff" -print | grep -iv "\-${pol}\-"`;do
		  ciop-log "INFO" "Removing file $file"
		  rm ${file} > /dev/null 2<&1
	      done
	  fi
	  echo ${safedir}
	  return $SUCCESS
      }
      
      echo `readlink -f ${safe_archive}`
      return $SUCCESS
  fi 

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

  #check for empty measurement and annotation lists
  if [ -z "${measurlist}" ]; then
      ciop-log "ERROR" "file ${safe_archive} contains no measurement files"
      return ${ERRINVALID}
  fi
  
  if [ -z "${annotlist}" ]; then
      ciop-log "ERROR" "file ${safe_archive} contains no annotation files"
      return ${ERRINVALID}
  fi
  


  for annotation in $annotlist
  do
     unzip -o -j ${safe_archive} "${annotation}" -d "${safe}/annotation" 1>&2
     res=$?
     ciop-log "INFO" "unzip ${annotation} : status $res"
     [ "${res}" != "0" ] && return ${res}
  done
  ciop-log "INFO" "Unzipped $( ls -l ${safe}/annotation )"
  for measurement in $measurlist
  do
    unzip -o -j ${safe_archive} "${measurement}" -d "${safe}/measurement" 1>&2
    res=$?
    ciop-log "INFO" "unzip ${measurement} : status $res"
    [ "${res}" != "0" ] && return ${res}    
  done
  
  if [ -n "`type -p gdalinfo`" ]; then
      #check the tiff files with gdalinfo
      local tif
      for tif in `find ${safe} -name *.tiff -print -o -name "*.tif" -print`; do
	  gdalinfo "${tif}" > /dev/null 2<&1
	  res=$?
	  [ "${res}" != "0" ] && {
	      ciop-log "INFO" "tiff file ${tif} is invalid . gdalinfo status $res"
	  }
      done
  fi

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

  #check images before downloading
  ref_check ${masterref} || {
      ciop-log "ERROR" "Input master image unsupported"
      return $ERRINVALID
  }
  
  ref_check ${slaveref} || {
      ciop-log "ERROR" "Input slave image unsupported"
      return $ERRINVALID
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

  
  masterinfo=($(opensearch-client -m EOP  "${masterref}" operationalMode))
  slaveinfo=($(opensearch-client -m EOP "${slaveref}" operationalMode))
  
#make sure master and slave modes match (IW and IW , or EW and EW)
  if [ "${masterinfo}"  !=  "${slaveinfo}" ]; then
      ciop-log "ERROR : slave and master image are from different modes"
      exit ${ERRINVALID}
fi



mode="${masterinfo}"
nswaths=0
case $mode in
    *IW*)nswaths=3;;
    *EW*)nswaths=5;;
    *)nswaths=0;;
esac

if [ $nswaths -eq 0 ]; then
    ciop-log "ERROR"  "master image invalid mode ${mode}"
    exit ${ERRINVALID}
fi



  ciop-log "INFO" "Extracting master"
  master_safe=$( extract_safe ${master} ${datadir}/data/master )
  [ "$?" != "0" ] && { 
      ciop-log "ERROR" "Error extracting ${master}"
      return ${ERRGENERIC}
}
  ciop-log "INFO" "Extracting slave"
  slave_safe=$( extract_safe ${slave} ${datadir}/data/slave )
  [ "$?" != "0" ] && { 
      ciop-log "ERROR" "Error extracting ${slave}"
      return ${ERRGENERIC}
}
  refmaster=`basename ${master_safe}`
  refslave=`basename ${slave_safe}`

#save products names
  masterid=${datadir}/masterid.txt
  opensearch-client -f atom "${masterref}" identifier > ${masterid}
  slaveid=${datadir}/slaveid.txt
  opensearch-client -f atom "${slaveref}" identifier > ${slaveid}
  ciop-publish -a "${masterid}"
  ciop-publish -a "${slaveid}"

#pass inputs as well as swath number to next node
for swath in `seq 1 ${nswaths}`; do
    echo "$refmaster@${swath}@$refslave@${swath}@$pol" | ciop-publish -s
done

#stage-out the results
ciop-publish "${master_safe}" -r -a || return $?
ciop-publish "${slave_safe}" -r -a || return $?
local fslist=`find ${master_safe} -type f -print`
ciop-log "DEBUG" "Master folder file list"
ciop-log "DEBUG" "${fslist}"

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
    res=$?
    [ "${res}" != "0" ] && {
	procCleanup
	exit ${res}
    }
    procCleanup
    exit ${SUCCESS}
done

