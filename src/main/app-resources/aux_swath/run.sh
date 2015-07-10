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


#read the inputs from stdin
#each line has master and slave s1 image , separated by semicolon
while read data
do

if [ -z "${data}" ]; then
    break
fi



inputs=(`echo "$data" | sed 's@[,;]@ @g'`)

#check the number of inputs
ninputs=${#inputs[@]}

if [ $ninputs  -lt 2 ]; then
    ciop-log "ERROR" "2 inputs expected, got ${ninputs}"
    exit ${ERRMISSING}
fi


# refmaster , refslave are supposed to
# be safe file paths
refmaster=${inputs[0]}
refslave=${inputs[1]}

ciop-log "INFO" "refmaster is $refmaster"
ciop-log "INFO" "refslave is $refslave"

#master input check
product_check "${refmaster}" || {
    status=$?
    ciop-log "ERROR : invalid  master input"
    exit $status
}

#slave input check
product_check "${refslave}" || {
    status=$?
    ciop-log "ERROR : invalid slave input"
    exit $status
}

masterinfo=($(product_name_parse "${refmaster}"))
slaveinfo=($(product_name_parse "${refslave}"))

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

#pass inputs as well as swath number to next node
for swath in `seq 1 ${nswaths}`; do
    echo "$refmaster@${swath}@$refslave@${swath}@$pol" | ciop-publish -s
done

done

exit "${SUCCESS}"
