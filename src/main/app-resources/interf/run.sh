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


#trap signals                                                                                                                       
function trapFunction()
{
    procCleanup
    ciop-log "ERROR" "Signal was trapped"
    exit
}


function get_available_swath_list()
{
    runid=""
    if [ $# -ge 1 ]; then
	runid=$1
    fi
    
    idopt=""
    if [ -n "${runid}" ]; then
	idopt="-r ${runid} "
    fi
    
    swathlist=$(ciop-browseresults ${idopt} | grep SW[0-9]*_BURST  | xargs -L1 sh -c 'basename $1 2>/dev/null' arg | sed 's@\(SW\)\([0-9]*\)\(.*\)@\2@g' | sort -n --unique )
    echo $swathlist
    [ -z "${swathlist}" ] && return 1
    
    return 0
}

#parameters :
#master_orbit , swath_number list,processing directory
function get_master_deburst_input()
{
    if [ $# -lt 3 ];then
	return ""
    fi

    local masterorb=$1
    local swathlist=$2
    local rootdir=$3
    
    local inputstring=""
    
    for sw in $swathlist; do
	str=$(printf "%s" "1\n${rootdir}/SW${sw}_DEBURST/DAT/GEOSAR/${masterorb}.geosar\nf=${rootdir}/SW${sw}_DEBURST/SLC_CI2/${masterorb}_SLC.ci2\nNone\n" )
	inputstring=$inputstring$str
    done
    inputstring=$(printf "%s%s" "$inputstring" "0\n1\nconv,typ=ci2\nf=${rootdir}/MERGE/${master}_SLC.ci2\n${rootdir}/MERGE/${masterorb}.geosar")
    

    echo $inputstring
    return 0
}
#parameters :
#master_orbit , slave orbit , swath_number list,processing directory
function get_slave_deburst_input()
{
    if [ $# -lt 4 ];then
	return ""
    fi

    local masterorb=$1
    local slaveorb=$2
    local swathlist=$3
    local rootdir=$4
    
    local inputstring=""
    
    for sw in $swathlist; do
	str=$(printf "%s" "1\n${rootdir}/SW${sw}_DEBURST/DAT/GEOSAR/${masterorb}.geosar\nf=${rootdir}/SW${sw}_DEBURST/SLC_CI2/geo_${slaveorb}_${masterorb}_RERAMP.cr4\nNone\n")
	inputstring=$inputstring$str
    done

    inputstring=$(printf "%s%s" "$inputstring" "0\n1\nconv,typ=ci2\nf=${rootdir}/MERGE/geo_${slaveorb}_${masterorb}.ci2\n${rootdir}/MERGE/temp.geosar")
    #
    
    echo $inputstring
    return 0
}



function merge_dems()
{
    if [ $# -lt 1 ]; then
	return 1
    fi
    
    if [ -z "`type -p gdalwarp`" ]; then
	#ciop-log "ERROR" "gdalwarp utility not available"
	return 2
    fi
    
    local outdir=$1
    local demlist=""
    local wkid=${_WF_ID}
    #look for the dems to merge in geotiff
    for dem in `ciop-browseresults -r ${wkid}  -j node_burst | grep -i dem | grep -i tif`; do
	hadoop dfs -copyToLocal "$dem" "${outdir}"
	flist="${flist} ${outdir}/`basename $dem`"
    done
    
    declare -a arrdem=(`echo $flist`)
    
    if [ ${#arrdem[@]} -le 0 ]; then
	#ciop-log "ERROR" "input dem missing"
	return 3
    fi

    local outdem=${outdir}/dem_merged.tif

    local mergecmd="gdalwarp -ot Int16 -r bilinear ${flist} ${outdem}"
    
    eval "${mergecmd}"
    
    local status=$?
    
    return $status
}


#produce swath level debursted coregistered slc
#inputs are master_orbit slave_orbit swath_number processing_directory input_dem
function deburst_swath()
{

    if [ $# -lt 4 ]; then
	retrurn 1
    fi

    master=$1
    slave=$2
    swath=$3
    procdir=$4
    indem=$5

    ciop-log "INFO" "master orbit is ${master}"
    ciop-log "INFO" "slave orbit is ${slave}"
    ciop-log "INFO" "swath number is ${swath}"
    ciop-log "INFO" "processing directory : ${procdir}"
    ciop-log "INFO" "input dem is : ${indem}"
    ciop-log "INFO" "swath is $swath"
    
    #create dem descriptor from input geotiff dem
    tifdemimport.pl --intif="${indem}" --outdir="${procdir}" --exedir="${EXE_DIR}" --datdir="${DAT_DIR}" >  "${procdir}/demimport.log" 2<&1
    
    masterburst=-1
    
    #use the workflow id
    local wkid=${_WF_ID}

    # stage in results from previous node
    for r in `ciop-browseresults -r ${wkid}  -j node_coreg | grep "SW${swath}_BURST_[0-9]*" | sort -n`; do
	hadoop dfs -copyToLocal "$r" "${procdir}"

	status=$?

	if [ $status -ne 0 ]; then
	    ciop-log "ERROR" "Failed to import $r to local storage"
	    return $status
	fi
    done 

    #look for first master burst

    minmaxburst=(`ls ${procdir}/ | grep SW${swath} | sed 's@\(SW[0-9]*_BURST_\)\([0-9]*\)@\2@g' | sort -n | sed -n '1p;$p'`)

    if [  ${#minmaxburst[@]} -lt 2 ]; then
   
	return $ERRINVALID
    fi 

    burst0=${minmaxburst[0]}
    burstn=${minmaxburst[1]}
    
    ciop-log "INFO" "burst0 $burst0 burstn ${burstn}"

    if [ -z "${burst0}" ]; then
	ciop-log "ERROR" "cannot determine initial burst for swath $swath"
	return 1
    fi

   masterburst=$burst0
    
#fix the paths in the geosar
    for g in `find ${procdir} -iname "*.geosar" -print | grep "SW${swath}_BURST_[0-9]*"`; do
	
	oldorb=`grep -ih "ORBITAL FILE" "$g" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
	if [ -z "$oldorb" ]; then
	#error
	    echo "missing orbital file for $g"
	    exit 255
	fi
	
	olddir=`dirname ${oldorb}`
	olddir=`dirname ${olddir}`
	dirgeosar=`dirname ${g}`
	dirgeosar=`readlink -f ${dirgeosar}/../../`
	
	cmd="perl -pi -e 's@"$olddir"@"${dirgeosar}"@g' \"$g\""
	eval "$cmd"
    done
    
#
    mkdir -p ${procdir}/SW${swath}_DEBURST/{DAT/GEOSAR,SLC_CI2,GEO_CI2,log,DIF_INT,TEMP,ORB}
    deburstdir=${procdir}/SW${swath}_DEBURST
    
    masterlist=${deburstdir}/DAT/master.txt
    
    slavelist=${deburstdir}/DAT/slave.txt
    
    for b in `seq $burst0 $burstn`;do
	echo ${procdir}/SW${swath}_BURST_$b/SLC_CI2/${master}_SLC.ci2 >> "${masterlist}"
	echo ${procdir}/SW${swath}_BURST_$b/GEO_CI2/geo_${slave}_${master}_RERAMP.cr4 >> "${slavelist}"
    done
    

#debursting
    tops_deburst.pl --geosarin=${procdir}/SW${swath}_BURST_${masterburst}/DAT/GEOSAR/${master}.geosar --geosarout=${deburstdir}/DAT/GEOSAR/${master}.geosar --exedir="${EXE_DIR}" --outdir="${deburstdir}/SLC_CI2/" --list=${masterlist} --tmpdir="${procdir}/TEMP" > ${deburstdir}/log/deburst_${master}.log 2<&1

    tops_deburst.pl --geosarin=${procdir}/SW${swath}_BURST_${masterburst}/DAT/GEOSAR/${master}.geosar  --exedir="${EXE_DIR}" --outdir="${deburstdir}/SLC_CI2/" --list=${slavelist} --tmpdir="${procdir}/TEMP" > ${deburstdir}/log/deburst_${slave}.log 2<&1

#swath level interf
    slavegeo=${procdir}/SW${swath}_BURST_${masterburst}/DAT/GEOSAR/${slave}.geosar
    cp ${slavegeo} ${deburstdir}/DAT/GEOSAR/${slave}.geosar
    
    
    return ${SUCCESS}
}

# merge swath interf results
# inputs are master_orbit,slave_orbit,processing_directory, dem, swath list
function merge_swaths()
{
    
    if [ $# -lt 7 ]; then
	return 1
    fi

    local master=$1
    local slave=$2
    local procdir=$3
    local demmerge=$4
    local mlaz=$5
    local mlran=$6
    local swathlist=$7
    local nsw=`echo $swathlist | wc -w`

    mergedir=${procdir}/MERGE

    mkdir -p ${mergedir} || {
	ciop-log "ERROR" "Failed to create directory ${mergedir}"
	return ${ERRPERM}
    }
    
    if [ $nsw -gt 1 ]; then
	master_input=$(get_master_deburst_input "${master}" "${swathlist}" "${procdir}") 
	
        #merge master
	echo -e  "${master_input}" | ${EXE_DIR}/swath_merge  > "${mergedir}"/merge_${master}.log 2<&1
	
	slave_input=$(get_slave_deburst_input "${master}" "${slave}" "${swathlist}" "${procdir}")
	
        #merge slave
	echo -e "${slave_input}" | ${EXE_DIR}/swath_merge  > "${mergedir}"/merge_${slave}.log 2<&1
    else
	#case where there is only 1 subswath , no need to merge 
	local sw_=`echo $swathlist | awk '{print $1}' | head -1 | sed 's@[^0-9]@@g'`
	diapconv.pl --mode=copy --type=ci2 --infile="${procdir}/SW${sw_}_DEBURST/SLC_CI2/${master}_SLC.ci2" --outfile="${mergedir}/${master}_SLC.ci2" --exedir="${EXE_DIR}" > "${mergedir}"/merge_${master}.log 2<&1
	cp "${procdir}/SW${sw_}_DEBURST/DAT/GEOSAR/${master}.geosar" "${mergedir}" >> "${mergedir}"/merge_${master}.log 2<&1
	diapconv.pl --mode=copy --type=ci2 --infile="${procdir}/SW${sw_}_DEBURST/SLC_CI2/geo_${slave}_${master}_RERAMP.cr4" --outfile="${mergedir}/geo_${slave}_${master}.ci2" --exedir="${EXE_DIR}" > "${mergedir}"/merge_${slave}.log 2<&1
    fi
    
mkdir -p ${mergedir}/DIF_INT

#fix geosar
perl -pi -e 's@\(AZIMUTH DOPPLER VALUE\)\([[:space:]]*\)\([^\n]*\)@\1\20.0@g' "${mergedir}/${master}.geosar"

sw=`echo $swathlist | awk '{print $1}' | head -1 | sed 's@[^0-9]@@g'`

#create interferogram
local psfiltopt=""
[ -n "${psfiltx}" ] && psfiltopt="--psfiltx=${psfiltx}"
interf_sar.pl --prog=interf_sar --master=${mergedir}/${master}.geosar --ci2master="${mergedir}/${master}_SLC.ci2"  --ci2slave="${mergedir}/geo_${slave}_${master}.ci2" --exedir="${EXE_DIR}" --mlaz=${mlaz} --mlran=${mlran} --dir="${mergedir}/DIF_INT" --amp --coh --nobort --noran --noinc --outdir="${mergedir}/DIF_INT"  --demdesc="${demmerge}" --slave=${procdir}/SW${sw}_DEBURST/DAT/GEOSAR/${slave}.geosar --ortho --psfilt "${psfiltopt}" --orthodir="${mergedir}/DIF_INT"   > "${mergedir}"/interf.log 2<&1

#create geotiff results
ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/coh_${master}_${slave}_ml${mlaz}${mlran}_ortho.rad" --demdesc="${demmerge}" --outfile="${mergedir}/DIF_INT/coh_${master}_${slave}_ortho.tiff" >> "${mergedir}"/coh_ortho.log 2<&1

ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/amp_${master}_${slave}_ml${mlaz}${mlran}_ortho.rad" --demdesc="${demmerge}" --outfile="${mergedir}/DIF_INT/amp_${master}_${slave}_ortho.tiff" >> "${mergedir}"/amp_ortho.log 2<&1

ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/psfilt_${master}_${slave}_ml${mlaz}${mlran}_ortho.rad" --mask --alpha="${mergedir}/DIF_INT/amp_${master}_${slave}_ml${mlaz}${mlran}_ortho.rad"  --demdesc="${demmerge}" --outfile="${mergedir}/DIF_INT/pha_${master}_${slave}_ortho.tiff" --colortbl=BLUE-RED  >> "${mergedir}"/pha_ortho.log 2<&1


#crop output geotiffs if aoi is set
declare -a aoi
[ -n "$inputaoi" ] && aoi=(`echo "${inputaoi}" | sed 's@,@ @g'`)

[ ${#aoi[@]} -ge 4 ]   && {

    for geotiff in `find "${mergedir}/DIF_INT" -iname "*.tiff" -print -o -iname "*.tif" -print`;do
	target=${mergedir}/temp.tiff
	gdalwarp -te ${aoi[0]} ${aoi[1]} ${aoi[2]} ${aoi[3]} -r bilinear "${geotiff}" "${target}" >> ${mergedir}/tiffcrop.log 2<&1
	mv "${target}" "${geotiff}"
    done
}


#publish results
ciop-publish -m "${mergedir}/DIF_INT/*.tiff" 
ciop-publish "${mergedir}/*.log" -r -a
find ${procdir} -iname "*.log" -exec ciop-publish "${mergedir}/*.log" -r -a '{}' \;

#convert all the tif files to png so that the results can be seen on the GeoBrowser

#first do the coherence and amplitude ,for which 0 is a no-data value
for tif in `find "${mergedir}/DIF_INT/"*.tiff* -print`; do
    target=${tif%.*}.png
    gdal_translate -scale -oT Byte -of PNG -co worldfile=yes -a_nodata 0 "${tif}" "${target}" >> "${mergedir}"/ortho.log 2<&1
    #convert the world file to pngw extension
    wld=${target%.*}.wld
    pngw=${target%.*}.pngw
    [ -e "${wld}" ] && mv "${wld}"  "${pngw}"
done

#convert the phase with imageMagick , which can deal with the alpha channel
if [ -n "`type -p convert`" ]; then
    phase=`ls ${mergedir}/DIF_INT/*pha*.tiff* | head -1`
    [ -n "$phase" ] && convert -alpha activate "${phase}" "${phase%.*}.png"
fi

#publish png and their pngw files
ciop-publish -m "${mergedir}"/DIF_INT/*.png
ciop-publish -m "${mergedir}"/DIF_INT/*.pngw


return 0

}



#begin
unset serverdir

#trap signals
trap trapFunction SIGHUP SIGINT SIGTERM


count=0

#get parameters
#export inputaoi=(`ciop-getparam aoi`)
export nodecleanup=(`ciop-getparam cleanup`)
export psfiltx=(`ciop-getparam psfiltx`)

while read data
do

#get the inputs
if [ -z "${data}" ]; then
    break
fi

if [ $count -gt 0 ]; then
    break
fi

inputs=($(echo "$data" | tr "@" "\n") )

ninputs=${#inputs[@]}

if [ $ninputs -lt 2 ] ; then
    ciop-log "ERROR" "Input master and slave orbit are not set"
    exit ${ERRMISSING}
fi
export serverdir=$(procdirectory "${TMPDIR}")

if [ -z "${serverdir}" ]; then
    ciop-log "INFO" "Failed to create processing directory"
    exit ${ERRPERM}
fi


master=${inputs[0]}
slave=${inputs[1]}


ciop-log "INFO" "Master orbit is ${master}"
ciop-log "INFO" "Slave orbit is ${slave}"


swath_list=$(get_available_swath_list ${_WF_ID} )

if [ -z "${swath_list}" ]; then
    ciop-log "INFO" "No swath number list detected"
    procCleanup 
    exit "${ERRMISSING}"
fi 

  ciop-log "INFO" "swath list ${swath_list}"
  

merge_dems ${serverdir} || {
    echo "unable to merge dems ! $?"
    procCleanup
    exit ${ERRGENERIC}
}

localdem=${serverdir}/dem_merged.tif

for swath in ${swath_list} ; do

deburst_swath "${master}" "${slave}" ${swath} "${serverdir}" "${localdem}"
status=$?
ciop-log "INFO" "swath interf $status"

done


ciop-log "INFO" "Merging sub-swaths"
merge_swaths ${master} ${slave} "${serverdir}" "${serverdir}/dem.dat" 2 8 "${swath_list}"

let "count += 1"

[ "${nodecleanup}" == "true" ]  && {
    #delete intermediary results 
    nodelist="node_swath node_burst node_coreg node_interf"
    local wkid_=${_WF_ID}
    for node in $nodelist ; do
	for d in `ciop-browseresults -r "${wkid_}" -j ${node}`; do
	    hadoop dfs -rmr $d > /dev/null 2<&1
	done
    done
}

procCleanup



done

exit ${SUCCESS}
