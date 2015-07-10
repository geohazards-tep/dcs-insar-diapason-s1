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
    ciop-log "ERROR" "Signal was trapped"
    exit
}


#export dem="`ciop-getparam dem`"

function main()
{
    if [ $# -lt 1 ]; then
	return $ERRMISSING
    fi
    
    local inputdata=("${!1}")
    
    if [ ${#inputdata[@]}  -lt 8  ];then
	return $ERRINVALID
    fi

    local orbitmaster=${inputdata[1]}
    local swathmaster=${inputdata[2]}
    local burstmaster=${inputdata[3]}
    
    ciop-log "INFO" "orbitmaster is $orbitmaster"
    ciop-log "INFO" "swathmaster is $swathmaster"
    ciop-log "INFO" "burstmaster is $burstmaster"
    
    local orbitslave=${inputdata[5]}
    local swathslave=${inputdata[6]}
    local burstslave=${inputdata[7]}
    local pol=${inputdata[8]}

    ciop-log "INFO" "orbitslave is $orbitslave"
    ciop-log "INFO" "swathslave is $swathslave"
    ciop-log "INFO" "burstslave is $burstslave"
    ciop-log "INFO" "polarization is $pol"
    


    unset serverdir
    #export serverdir=$(procdirectory "${TMPDIR}")
    export serverdir="${TMPDIR}/SW${swathmaster}_BURST_${burstmaster}"
    mkdir -p ${serverdir}/{DAT/GEOSAR,RAW_C5B,SLC_CI2,ORB,TEMP,log,QC,GRID,DIF_INT,CD,GEO_CI2,VOR} || {
	return ${ERRPERM}
    }

    ciop-log "INFO" "created processing directory ${serverdir}"

    #look for the dem
    local publishdem=`ciop-browseresults  -j node_burst | grep dem_${swathmaster}.tif | head -1`

    if [ -z "${publishdem}" ]; then
	ciop-log "INFO" "unable to locate dem from previous node for swath ${swathmaster}"
	procCleanup
	return $ERRMISSING
    fi
    
    #copy dem
    hadoop dfs -copyToLocal "${publishdem}" "${serverdir}/DAT"
    
    
    ciop-log "INFO" "input dem is ${publishdem}"
    
    ciop-log "INFO" " mapred_local_dir ${mapred_local_dir}"
    
    #localdem=$(  get_data "${dem}" "${serverdir}/CD" )  
    local localdem=${serverdir}/DAT/`basename "${publishdem}"`
    
    if [ ! -e "${localdem}" ]; then
	ciop-log "INFO" "unable to import dem from previous node for swath ${swathmaster}"
	procCleanup
	return $ERRGENERIC
    fi

    ciop-log "INFO" "local dem is ${localdem}"
    

    #dem import
    tifdemimport.pl --intif="${localdem}" --outdir="${serverdir}/DAT/" --exedir="${EXE_DIR}" --datdir="${DAT_DIR}" >  "${serverdir}/log/demimport.log" 2<&1
    
    export DEM="${serverdir}/DAT/dem.dat"
    
    if [ ! -e "${DEM}" ]; then
	ciop-log "ERROR" "Failed to create dem descriptor"
	msg=`cat "${serverdir}/log/demimport.log"`
	ciop-log "INFO" "${msg}"
	procCleanup
	return ${ERRGENERIC}
    fi

    #master & slave are assumed to be local files
    master=$( get_data ${inputdata[0]} ${serverdir}/CD ) 
    statmaster=$?
    if [ "$statmaster" != "0" ]; then
	ciop-log "ERROR" "Failed to download input ${inputdata[0]}"
	procCleanup
	return ${ERRSTGIN}
    fi
    
    

    slave=$( get_data ${inputdata[4]}  ${serverdir}/CD ) 
    statslave=$?
    if [ "$statslave" != "0" ]; then
	ciop-log "ERRROR" "Failed to download input ${inputdata[3]}"
	procCleanup
	return ${ERRSTGIN}
    fi
   
    
    #extract data 
    handle_tars.pl  --pol=${pol}  --in="${master}"  --burst=${burstmaster}  --serverdir="${serverdir}" --swath=${swathmaster} --exedir="${EXE_DIR}" --tmpdir="${serverdir}/TEMP" > ${serverdir}/log/extract_master.log 2<&1
    
    
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
    handle_tars.pl --in="${slave}" --burst=${burstslave} --serverdir="${serverdir}" --swath=${swathslave} --exedir="${EXE_DIR}" --tmpdir="${serverdir}/TEMP" --pol="${pol}"  > ${serverdir}/log/extract_slave.log 2<&1
   
    norbits=`ls ${serverdir}/ORB/*.orb | wc -l`
    
    if [ $norbits -lt 2 ]; then
	ciop-log "ERROR" "Slave image extraction failure"
	msg=`cat "${serverdir}"/log/extract_slave.log`
	ciop-log "ERROR : ${msg}"
	procCleanup
	return  ${ERRGENERIC}
    fi
    
    ciop-log "INFO" "exctracted slave orbit ${orbitslave} pol ${pol}"
    
    #precise orbits
    for  g in `find "${serverdir}"/DAT/GEOSAR -iname "*.geosar" -print`;do 
	diaporb.pl --geosar="$g" --dir="${serverdir}/TEMP" --outdir="${serverdir}/ORB"  --type=s1prc --mode=1 > "${serverdir}/log/precise_orbits.log" 2<&1
    done
    #multilook
    
    find "${serverdir}/DAT/GEOSAR/" -iname "*.geosar" -print | ml_all.pl --type=byt --mlaz=2 --mlran=8 --dir="${serverdir}/SLC_CI2" > ${serverdir}/log/ml.log 2<&1

    #run geometric registration
    coreg.pl --geom --master=${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar --slave=${serverdir}/DAT/GEOSAR/${orbitslave}.geosar --nochangeo --griddir=${serverdir}/GRID --exedir="${EXE_DIR}" --demdesc=${serverdir}/DAT/dem.dat --azinterval=10 --raninterval=10 > "${serverdir}"/log/coreg.log 2<&1
    
    #deramp slave image
    ${EXE_DIR}/deramp_s1_tops --deramp > "${serverdir}"/log/deramp_${orbitslave}.log 2<&1 <<EOF
${serverdir}/DAT/GEOSAR/${orbitslave}.geosar
${serverdir}/SLC_CI2/${orbitslave}_sw${swathslave}_${pol}.xml
f=${serverdir}/SLC_CI2/${orbitslave}_SLC.ci2
None
1
conv,typ=cr4
f=${serverdir}/SLC_CI2/${orbitslave}_SLC_DERAMP.cr4
0
EOF

    tops_shift_and_reramp.pl --exedir="${EXE_DIR}" --ci2slave="${serverdir}/SLC_CI2/${orbitslave}_SLC_DERAMP.rad" --outdir="${serverdir}/GEO_CI2" --master="${serverdir}/DAT/GEOSAR/${orbitmaster}.geosar" --slave="${serverdir}/DAT/GEOSAR/${orbitslave}.geosar" --gridfile="${serverdir}/GRID/GRID_${orbitmaster}_${orbitslave}.dat" >> "${serverdir}/log/changeo_reramp_${orbitslave}.log" 2<&1
    
    local shiftst=$?
    local geo="${serverdir}/GEO_CI2/geo_${orbitslave}_${orbitmaster}.cr4"
    if [ $shiftst -ne 0 ] && [ ! -e "$geo"  ]; then
	sz=$(stat -c%s ${serverdir}/SLC_CI2/${orbitslave}_SLC_DERAMP.cr4)
	dd if=/dev/zero bs=$sz count=1 > "${geo}" 2<&1
    fi

    #cleanup before publishing
    rm -f ${serverdir}/SLC_CI2/${orbitslave}_SLC* 2>/dev/null
    rm -f ${serverdir}/CD/* 2>/dev/null
    rm -f ${serverdir}/CD/* 2>/dev/null
    rm -f ${serverdir}/DAT/*.tif 2>/dev/null
    rm -f ${serverdir}/DAT/dem* 2>/dev/null
    
    
    ciop-publish "${serverdir}" -r -a
    
    procCleanup

    return ${SUCCESS}
}

#read the inputs from stdin
#each line has : master image@orbit number@swath number@master burst@slave image@orbit number@swath number@slave burst@polarization
while read data
do

if [ -z "${data}" ]; then
    break
fi

inputs=($(echo "$data" | tr "@" "\n") )

ninputs=${#inputs[@]}

ciop-log "INFO" "ninputs : ${ninputs} ,${inputs[@]}"
ciop-log "INFO" "CIOP_WF_RUN_ID ${CIOP_WF_RUN_ID}"
ciop-log "INFO" "RUN ID is ${RUN_ID}"


if [ $ninputs -eq 9 ]; then
    main inputs[@] 
    
    #pass orbit master@orbit slave to next node
    echo "${inputs[1]}@${inputs[5]}" | ciop-publish -s
fi

done

exit ${SUCCESS}