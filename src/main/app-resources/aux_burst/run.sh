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
	procCleanup
	exit $ERRMISSING
    fi

    hadoop dfs -copyToLocal "${pubmaster}" "${serverdir}/CD" 
    local statmaster=$?
    if [ "$statmaster" != "0" ]; then
	ciop-log "ERROR" "Failed to stage in ${inputdata[0]}"
	procCleanup
	exit ${ERRSTGIN}
    fi
    local master="${serverdir}/CD/${inputdata[0]}"
    
    ciop-log "INFO" "local master is $master"
 
    local swathmaster=${inputdata[1]}
    
    
    #now get the slave safe 
    local pubslave=`ciop-browseresults -r ${wkid}  -j node_swath | grep ${inputdata[2]} | head -1`
    
    if [ -z "${pubslave}" ]; then
	ciop-log "ERROR" "Failed to locate slave safe"
	procCleanup
	exit $ERRMISSING
    fi
    
    hadoop dfs -copyToLocal "$pubslave" "${serverdir}/CD"

    local statslave=$?
    if [ "$statslave" != "0" ]; then
	ciop-log "ERRROR" "Failed to stage in ${inputdata[2]}"
	procCleanup
	exit ${ERRSTGIN}
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
        exit ${ERRGENERIC}
    fi
    
    #get polarization
    pol=`grep -ih "^POLARI" "${serverdir}/DAT/GEOSAR/"*.geosar | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    if [ -z "${pol}" ]; then
	ciop-log "ERROR" "Master image extraction failure"
        msg=`cat "${serverdir}"/log/extract_master.log`
        ciop-log "ERROR : ${msg}"
        procCleanup
        exit ${ERRGENERIC}
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
	exit  ${ERRGENERIC}
    fi
    
    orbitslave=`ls -tra "${serverdir}/DAT/GEOSAR/"*.geosar | tail -1 | xargs grep -ih "ORBIT NUMBER" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    
    if [ -z "${orbitslave}" ]; then
        ciop-log "ERROR" "Slave image extraction failure"
        msg=`cat "${serverdir}"/log/extract_slave.log`
        ciop-log "ERROR : ${msg}"
        procCleanup
        exit ${ERRGENERIC}
    fi
 
    ciop-log "INFO" "exctracted slave orbit ${orbitslave} pol ${pol}"

    #download dem
    get_DEM "${serverdir}"  || {
	#no DEM exit
	ciop-log "ERROR" "dem download fail"
	local demmissingflag=${serverdir}/TEMP/demmissing_sw${swathmaster}.txt
	touch "${demmissingflag}" || exit ${ERRGENERIC}
	ciop-publish -a "${demmissingflag}" || exit ${ERRGENERIC}
	procCleanup
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
	exit ${ERRGENERIC}
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
    local burstmaster=${BURSTSTART}

    #pass master@swath_master@burst_master@slave@swath_slave@burst_slave@ to next node
    for burst in `seq 0 $((nbursts-1))`; do
	burstslave=${SLAVEBURSTLIST[$burst]}
	#echo "${inputdata[0]}@${orbitmaster}@${inputdata[1]}@${burstmaster}@${inputdata[2]}@${orbitslave}@${inputdata[3]}@${burstslave}@$pol" | ciop-publish -s
	let "burstmaster += 1" 
    done
    
    #if an aoi was defined by the user
    #record it in a file and publish it
    # in hdfs so next nodes can retrieve it
    if [ -n "${inputaoi}" ]; then
	local aoifile="${serverdir}/TEMP/aoi.txt"
	echo "${inputaoi}" > "${aoifile}"
	ciop-publish  -a "${aoifile}"
    fi

    #create a directory for the subswath coregistration process
    local esddir=`mktemp -d "${TMPDIR}/coreg_s1_XXXXXX"`

    if [ -z "${esddir}" ]; then
	ciop-log "ERROR" "Cannot create processing directory"
	procCleanup
	exit ${ERRGENERIC}
    fi

    mkdir -p ${esddir}/{CD,DEM,DAT} || {
	ciop-log "ERROR" "Cannot create processing directory"
	procCleanup
	exit ${ERRGENERIC}
}

    #move the extracted products to the CD subdirectory
    mv ${serverdir}/CD/* ${esddir}/CD/

    #create the DEM descriptor
    tifdemimport.pl --intif="${tifdem}" --outdir="${esddir}/DEM/" --exedir="${EXE_DIR}" --datdir="${DAT_DIR}" >  "${esddir}/DEM/demimport.log" 2<&1
    
    #cleanup serverdir processing directory
    procCleanup
    
    export serverdir="${esddir}"

    export DEM="${esddir}/DEM/dem.dat"
    
    if [ ! -e "${DEM}" ]; then
	ciop-log "ERROR" "Failed to create dem descriptor"
	msg=`cat "${esddir}/DEM/demimport.log"`
	ciop-log "INFO" "${msg}"
	procCleanup
	exit ${ERRGENERIC}
    fi

    #define environment
    export ROOT_DIR="${esddir}"
    
    #SCRIPTS DIRECTORY
    export SCRIPT_DIR="/opt/diapason/gep.dir/"
    export PRODUCT1="${serverdir}/CD/${inputdata[0]}"
    export PRODUCT2="${serverdir}/CD/${inputdata[2]}"
    
    #MULTILOOK PARAMETERS
    export MLAZ=2
    export MLRAN=8
    
    #SWATH TO PROCESS
    #USED BY process_tops_insar_icc.sh SCRIPT
    #MAY BE LEFT BLANK WHEN RUNNING tops_sack.sh
    export SWATH=${swathmaster}
    
    
    #SLIDNIG WINDOW FOR ESD
    export ESD_WINAZI=4
    export ESD_WINRAN=16
    
    #POLARIZATION TO PROCESS
    #LEAVE BLANK IF UNKNOWN
    export POL


      #number of iterations for the ESD process
    export NESDITER=2
    local ESDTAG=`echo "${NESDITER} - 1" | bc -l` 
    #aoi
    if [ -n "${inputaoi}" ]; then
	local AOI_SHP=$(aoi2shp "${inputaoi}" "${esddir}/DAT" "aoi")
	[ -n "${AOI_SHP}" ] && {
	    export AOI_SHP
	}
    else
	unset AOI_SHP
    fi

    #processing
    ${SCRIPT_DIR}/s1_process_swath.sh > ${esddir}/process_sw${swathmaster}.log 2<&1
    chmod -R 775 ${esddir}
    local procesdstatus=$?

    if [ ${procesdstatus} -ne 0  ]; then
	ciop-log "ERROR" "procesing of swath ${swathmaster} failed"
	cp ${esddir}/*.log /tmp
	cp ${esddir}/*.log /tmp
	cp ${esddir}/*.dat /tmp
	procCleanup
	exit ${ERRGENERIC}
    fi
    
    
    
    #look for the processing directories to publish to next node
    burstmaster=${BURSTSTART}
    
    #for every burst
    for burst in `seq 0 $((nbursts-1))`; do
	local procburstdir="${esddir}/SW_${swathmaster}_POL_${POL}_BURST_${burstmaster}"
	
	 #clean the directory
	rm -rf ${procburstdir}/DIF_INT* 2>/dev/null
	rm -f ${procburstdir}${GEO_CI2}/*
	rm -f ${procburstdir}${GEO_CI2_EXT_LIN}/* 2>/dev/null
	rm -f ${procburstdir}/SLC_CI2/${orbitslave}*SLC* 2>/dev/null
	rm -f ${procburstdir}/SLC_CI2/*DERAMP* 2>/dev/null
	mv ${procburstdir}/ESD_iter_glob_${ESDTAG}/geo*RERAMP*.* ${procburstdir}/GEO_CI2/
	rm -f ${procburstdir}/GEO_CI2/geo_${orbitmaster}*.* 2>/dev/null
	rm -rf ${procburstdir}/ESD_iter_glob_${ESDTAG}/*
	mv ${procburstdir} ${esddir}/SW${swathmaster}_BURST_${burstmaster}
	rm -rf ${procburstdir}/*DEBURSTED*
	procburstdir=${esddir}/SW${swathmaster}_BURST_${burstmaster}
	#publish to next node
	ciop-publish "${procburstdir}" -r -a
	local pubstatus=$?
	if [ ${pubstatus} -ne 0 ]; then
	    ciop-log "ERROR" "Failed to publish directory for burst ${burst} swath ${swathmaster}:$pubstatus"
	    procCleanup
	    exit ${ERRGENERIC}
	fi
	let "burstmaster += 1"
    done

    #pass orbit master@orbit slave to next node
    echo "${orbitmaster}@${orbitslave}" | ciop-publish -s

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


main inputs[@]




done


exit $SUCCESS
