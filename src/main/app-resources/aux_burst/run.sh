#!/bin/bash


#source the ciop functions
source ${ciop_job_include}

#source some utility functions
source $_CIOP_APPLICATION_PATH/lib/util.sh 

#setup the Diapason environment                                                                                                     
export LANGUE=en
export PERL5LIB=/opt/diapason/pldiap/lib
export PATH=$PATH:/opt/diapason/pldiap/bin
export EXE_DIR=/opt/diapason/exe.dir
export DAT_DIR=/opt/diapason/dat.dir
export exedir=${EXE_DIR}
export datdir=${DAT_DIR}

#
#trap signals                                                                                                                       
trap trapFunction SIGHUP SIGINT SIGTERM


#
#trap signals                                                                                                                       
function trapFunction()
{
    procCleanup
    ciop-log "ERROR : Signal was trapped"
    exit
}

#get parameters
export inputaoi=(`ciop-getparam aoi`)

#main
function main()
{
    if [ $# -lt 1 ]; then
	return $ERRMISSING
    fi
    
    local inputdata=("${!1}")

    if [ ${#inputdata[@]}  -lt 5  ];then
	return $ERRINVALID
    fi

    unset serverdir
    export serverdir=$(procdirectory "${TMPDIR}")

    ciop-log "INFO" "created processing directory ${serverdir}"

    #get the workflow id
    local wkid=${_WF_ID}
    
    ciop-log "INFO" "wkid is ${wkid}"


    #master & slave are assumed to be safe directory names published by node_swath
    local pubmaster=`ciop-browseresults -r ${wkid} -j node_swath | grep ${inputdata[0]} | head -1`
    
    if [ -z "${pubmaster}" ]; then
	ciop-log "ERROR" "Failed to locate master safe"
	return $ERRMISSING
    fi

    hadoop dfs -copyToLocal "${pubmaster}" "${serverdir}/CD" 
    local statmaster=$?
    if [ "$statmaster" != "0" ]; then
	ciop-log "ERROR" "Failed to stage in ${inputdata[0]}"
	procCleanup
	return ${ERRSTGIN}
    fi
    local master="${serverdir}/CD/${inputdata[0]}"
    
    ciop-log "INFO" "local master is $master"
 
    local swathmaster=${inputdata[1]}
    
    
    #now get the slave safe 
    local pubslave=`ciop-browseresults -r ${wkid}  -j node_swath | grep ${inputdata[2]} | head -1`
    
    if [ -z "${pubslave}" ]; then
	ciop-log "ERROR" "Failed to locate slave safe"
	return $ERRMISSING
    fi
    
    hadoop dfs -copyToLocal "$pubslave" "${serverdir}/CD"

    local statslave=$?
    if [ "$statslave" != "0" ]; then
	ciop-log "ERRROR" "Failed to stage in ${inputdata[2]}"
	procCleanup
	return ${ERRSTGIN}
    fi
    
    local slave="${serverdir}/CD/${inputdata[2]}"
    
    local swathslave=${inputdata[3]}

    #polarization
    local pol=${inputdata[4]}
    export POL="${pol}"
    #extract data 
    extract_any.pl  --pol=${pol} --in="${master}" --serverdir="${serverdir}" --swath=${swathmaster} --exedir="${EXE_DIR}" --tmpdir="${serverdir}/TEMP" > ${serverdir}/log/extract_master.log 2<&1
    
    #get master orbit number
    local orbitmaster=`grep -ih "ORBIT NUMBER" "${serverdir}/DAT/GEOSAR/"*.geosar | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    
    if [ -z "${orbitmaster}" ]; then
        ciop-log "ERROR" "Master image extraction failure"
        msg=`cat "${serverdir}"/log/extract_master.log`
        ciop-log "ERROR : ${msg}"
        procCleanup
        return ${ERRGENERIC}
    fi
    
    #get polarization
    pol=`grep -ih "^POLARI" "${serverdir}/DAT/GEOSAR/"*.geosar | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    if [ -z "${pol}" ]; then
	ciop-log "ERROR" "Master image extraction failure"
        msg=`cat "${serverdir}"/log/extract_master.log`
        ciop-log "ERROR : ${msg}"
        procCleanup
        return ${ERRGENERIC}
    fi
    
    ciop-log "INFO" "exctracted master orbit ${orbitmaster} pol ${pol}"

    #extract the slave image
    export POL=${pol}
    extract_any.pl --in="${slave}" --serverdir="${serverdir}" --swath=${swathslave} --exedir="${EXE_DIR}" --tmpdir="${serverdir}/TEMP" --pol="${pol}"  > ${serverdir}/log/extract_slave.log 2<&1
   
    local norbits=`ls ${serverdir}/ORB/*.orb | wc -l`
    
    if [ $norbits -lt 2 ]; then
	ciop-log "ERROR" "Slave image extraction failure"
	msg=`cat "${serverdir}"/log/extract_slave.log`
	ciop-log "ERROR : ${msg}"
	procCleanup
	return  ${ERRGENERIC}
    fi
    
    orbitslave=`ls -tra "${serverdir}/DAT/GEOSAR/"*.geosar | tail -1 | xargs grep -ih "ORBIT NUMBER" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    
    if [ -z "${orbitslave}" ]; then
        ciop-log "ERROR" "Slave image extraction failure"
        msg=`cat "${serverdir}"/log/extract_slave.log`
        ciop-log "ERROR : ${msg}"
        procCleanup
        return ${ERRGENERIC}
    fi
 
    ciop-log "INFO" "exctracted slave orbit ${orbitslave} pol ${pol}"

    #download dem
    get_DEM "${serverdir}"  || {
	#no DEM exit
	procCleanup
	ciop-log "ERROR" "dem download fail"
	return ${ERRGENERIC}
    }

    local tifdem="${serverdir}/DAT/dem.tif"
    
    if [ ! -e "${tifdem}" ]; then
	#no DEM exit
	procCleanup
	ciop-log "ERROR" "dem unavaiable"
	return ${ERRGENERIC}
    fi
    
    #rename the dem so that it has the swath number
    mv "${tifdem}" "${serverdir}/DAT/dem_${swathmaster}.tif"
    tifdem="${serverdir}/DAT/dem_${swathmaster}.tif"
    
    ciop-publish  -a "${tifdem}"
    
    status=$?
    
    if [ $status -ne 0 ]; then
	procCleanup
	ciop-log "ERROR" "unable to publish dem ,status :  $status"
	return ${ERRGENERIC}
    fi 
    
    local BURSTSTART=""
    local BURSTEND=""
    local SLAVEBURSTLIST=""
    
    local aoidef=""
    ciop-log "INFO" "input aoi ${inputaoi}"
    [ -n "${inputaoi}"  ] && {
	aoidef=`echo "${inputaoi}" | sed 's@,@ @g' | awk '{print "lon="$1",lat="$2",lon="$3",lat="$4}'`
	ciop-log "INFO" "aoidef:${aoidef}"
}

    matching_bursts  "${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" "${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" BURSTSTART BURSTEND SLAVEBURSTLIST "${aoidef}"
    status=$?
    
    [ $status -eq 3 ] && [ -n "${aoidef}" ] && {
	ciop-log "INFO" "aoi ${inputaoi} does not intersect with subswath ${swathmaster}"
	procCleanup
	return $SUCCESS
    }

    if [ $status -ne 0 ]; then
	ciop-log "ERROR" " Failed to determine master-slave matching bursts for subswath ${swathmaster}-> $status"
        procCleanup
        return ${ERRGENERIC}
    fi

    ciop-log "INFO" "Master starting burst  :${BURSTSTART}"
    ciop-log "INFO" "Master ending burst    :${BURSTEND}"
    ciop-log "INFO" "Slave burst index list :${SLAVEBURSTLIST[@]}"

    SLAVEBURSTLIST=(`echo ${SLAVEBURSTLIST[@]}`)


    nbursts=${#SLAVEBURSTLIST[@]}
    
    if [ $nbursts -lt 0 ]; then
	ciop-log "ERROR" " No valid burst found  for subswath ${swathmaster}"
	procCleanup
        return ${ERRGENERIC}
    fi
    burstmaster=${BURSTSTART}

    #pass master@swath_master@burst_master@slave@swath_slave@burst_slave@ to next node
    for burst in `seq 0 $((nbursts-1))`; do
	burstslave=${SLAVEBURSTLIST[$burst]}
	echo "${inputdata[0]}@${orbitmaster}@${inputdata[1]}@${burstmaster}@${inputdata[2]}@${orbitslave}@${inputdata[3]}@${burstslave}@$pol" | ciop-publish -s
	let "burstmaster += 1" 
    done

    #cleanup processing directory
    procCleanup
    
    return $SUCCESS
}


#read the inputs from stdin
#each line has : master image@swath number@slave image@swath number@polarization
while read data
do

if [ -z "${data}"  ]; then
    break
fi

inputs=($(echo "$data" | tr "@" "\n") )

ninputs=${#inputs[@]}

ciop-log "INFO" "Master image : "${inputs[0]}
ciop-log "INFO" "Slave  image : "${inputs[2]}


main inputs[@]  || {
    ciop-log "ERROR" "processing of inputs failed. status $?"
    continue
}




done


exit $SUCCESS
