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
    
    swathlist=$(ciop-browseresults ${idopt} -j node_burst | grep SW[0-9]*_BURST  | xargs -L1 sh -c 'basename $1 2>/dev/null' arg | sed 's@\(SW\)\([0-9]*\)\(.*\)@\2@g' | sort -n --unique )
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


function check_dems()
{
    if [ $# -lt 1 ]; then
	return $ERRMISSING
    fi

    local wkid_="$1"
    declare -a demlist
    demlist=(`ciop-browseresults -r ${wkid_}  -j node_burst | grep -i dem | grep -i tif`)
    
    if [ ${#demlist[@]}  -le 0 ]; then
	return $ERRMISSING
    fi

    return $SUCCESS
    
}


function merge_dems()
{
    if [ $# -lt 1 ]; then
	return 1
    fi
    
    if [ -z "`type -p gdalwarp`" ]; then
	ciop-log "ERROR" "gdalwarp utility not available"
	return ${ERRMISSING}
    fi
    
    local outdir=$1
    local demlist=""
    local wkid=${_WF_ID}

    local aoipath=`ciop-browseresults -r "${wkid}" -j node_burst | grep -i aoi | grep -i txt | head -1`
    local inputaoi=""
    local aoishape=""
    if [ -n "${aoipath}" ]; then
	ciop-copy "hdfs://${aoipath}" -q -O "${outdir}"
	local aoifile=${outdir}/`basename "${aoipath}"`
	inputaoi=`grep -m 1 "[0-9]" ${aoifile}`
    fi
    
    [ -n "$inputaoi" ] && aoi=(`echo "${inputaoi}" | sed 's@,@ @g'`)
    
    [ ${#aoi[@]} -ge 4 ]   && {
	aoi2shp "$inputaoi" "${outdir}" "AOI"
	aoishape="${outdir}/AOI.shp"
    }


    #look for the dems to merge in geotiff
    for dem in `ciop-browseresults -r ${wkid}  -j node_burst | grep -i dem | grep -i tif`; do
	ciop-copy "hdfs://${dem}" -q -O "${outdir}"
 	local stcopy=$?
	
	if [ $stcopy -ne 0 ]; then
	    ciop-log "ERROR" "Failed command: ciop-copy hdfs://${dem} -q -O ${outdir}"
	    return $ERRSTGIN
	fi

	flist="${flist} ${outdir}/`basename $dem`"
    done
    
    declare -a arrdem=(`echo $flist`)
    
    if [ ${#arrdem[@]} -le 0 ]; then
	ciop-log "ERROR" "input dem missing"
	return ${ERRMISSING}
    fi

    local outdem=${outdir}/dem_merged.tif

    local mergecmd="gdalwarp -tr 0.000416666666500 -0.000416666666500  -ot Int16 -r bilinear ${flist} ${outdem}"
    
    eval "${mergecmd}"
    
    local status=$?
    
    if [ $status -eq 0 ]; then
	local tmdem=${outdir}/dem_merged_cropped.tif
	local gdalcropbin="/opt/gdalcrop/bin/gdalcrop"
	if [ -e "${aoishape}" ] && [ -e "${gdalcropbin}" ]; then
	    ${gdalcropbin} ${outdem} ${aoishape} ${tmdem}
	    if [ -e "$tmdem" ]; then
		mv ${tmdem} ${outdem}
		chmod 777 ${outdem}
		#delete aoi path
		hadoop dfs -rm ${aoipath}
		ciop-log "INFO" "Cropped dem to aoi"
	    fi
	fi
    fi

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
    tifdemimport.pl --intif="${indem}" --outdir="${procdir}" --exedir="${EXE_DIR}" --datdir="${DAT_DIR}" >  "${procdir}/demimport_sw${swath}.log" 2<&1
    
    masterburst=-1
    
    #use the workflow id
    local wkid=${_WF_ID}

    # stage in results from previous node
    for r in `ciop-browseresults -r ${wkid}  -j node_burst | grep "SW${swath}_BURST_[0-9]*" | sort -n`; do
	ciop-copy "hdfs://${r}" -q -O "${procdir}"

	local status=$?

	if [ $status -ne 0 ]; then
	    ciop-log "ERROR" "Failed to import $r to local storage"
	    return $status
	fi
    done 
    
    #make sure the permissions are ok on the files imported from hdfs
    chmod -R 775 "${procdir}"

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
    
    masterlist=${deburstdir}/DAT/master_list_sw${swath}.txt
    local fmllist=${deburstdir}/DAT/master_deburst_input_list_sw${swath}.txt
    

    slavelist=${deburstdir}/DAT/slave_list_sw${swath}.txt
    local fsllist=${deburstdir}/DAT/slave_deburst_input_list_sw${swath}.txt
    
    for b in `seq $burst0 $burstn`;do
	echo ${procdir}/SW${swath}_BURST_$b/SLC_CI2/${master}_SLC.ci2 >> "${masterlist}"
	ls -l ${procdir}/SW${swath}_BURST_$b/SLC_CI2/${master}_SLC.* >> "${fmllist}" 2<&1
	echo ${procdir}/SW${swath}_BURST_$b/GEO_CI2/geo_${slave}_${master}_RERAMP.cr4 >> "${slavelist}"
	ls -l ${procdir}/SW${swath}_BURST_$b/GEO_CI2/geo_${slave}_${master}_RERAMP.* >> "${fsllist}" 2<&1
    done
    
    
#debursting
    tops_deburst.pl --geosarin=${procdir}/SW${swath}_BURST_${masterburst}/DAT/GEOSAR/${master}.geosar --geosarout=${deburstdir}/DAT/GEOSAR/${master}.geosar --exedir="${EXE_DIR}" --outdir="${deburstdir}/SLC_CI2/" --list=${masterlist} --tmpdir="${procdir}/TEMP" > ${deburstdir}/log/deburst_${master}_sw${swath}.log 2<&1
    local msstatus=$?

    [ $msstatus -ne 0 ] && {
	ciop-log "ERROR" "Debursting for swath $swath orbit ${master} failed"
	return $msstatus
    }
    
    grep "ci2" "${masterlist}" | xargs rm >> ${deburstdir}/log/deburst_${master}_sw${swath}.log 2<&1

    tops_deburst.pl --geosarin=${procdir}/SW${swath}_BURST_${masterburst}/DAT/GEOSAR/${master}.geosar  --exedir="${EXE_DIR}" --outdir="${deburstdir}/SLC_CI2/" --list=${slavelist} --tmpdir="${procdir}/TEMP" > ${deburstdir}/log/deburst_${slave}_sw${swath}.log 2<&1

    local slstatus=$?
    
    [ $slstatus -ne 0 ] && {
	ciop-log "ERROR" "Debursting for swath $swath orbit ${slave} failed"
	return $slstatus
    }
    
    grep "cr4" "${slavelist}" | xargs rm >> ${deburstdir}/log/deburst_${slave}_sw${swath}.log 2<&1

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
    
    #after merge remove debursted slc data
    local sw=""
    for sw in $swathlist; do
	find "${procdir}/SW${sw}_DEBURST"  -name "*.cr4" -print -o -iname "*.ci2" -print | xargs rm > /dev/null 2<&1 
    done

mkdir -p ${mergedir}/DIF_INT

#fix geosar
perl -pi -e 's@(AZIMUTH DOPPLER VALUE)([[:space:]]*)([^\n]*)@${1}${2}0.0@g' "${mergedir}/${master}.geosar"

#fix slave geosars as well
find "${procdir}" -name "*.geosar" -exec perl -pi -e 's@(AZIMUTH DOPPLER VALUE)([[:space:]]*)([^\n]*)@${1}${2}0.0@g' '{}' \;


sw=`echo $swathlist | awk '{print $1}' | head -1 | sed 's@[^0-9]@@g'`


#create interferogram
local psfiltopt=""
[ -n "${psfiltx}" ] && psfiltopt="--psfiltx=${psfiltx}"


interf_sar.pl --prog=interf_sar --master=${mergedir}/${master}.geosar --ci2master="${mergedir}/${master}_SLC.ci2"  --ci2slave="${mergedir}/geo_${slave}_${master}.ci2" --exedir="${EXE_DIR}" --winazi=${mlaz} --winran=${mlran}  --mlaz=1 --mlran=1 --dir="${mergedir}/DIF_INT" --amp --coh --nobort --noran --noinc --outdir="${mergedir}/DIF_INT"  --demdesc="${demmerge}" --slave=${procdir}/SW${sw}_DEBURST/DAT/GEOSAR/${slave}.geosar --ortho --psfilt "${psfiltopt}" --orthodir="${mergedir}/DIF_INT"   >> "${mergedir}"/interf_sw${sw}.log 2<&1

rm -f "${mergedir}/DIF_INT/amp*ortho*"

ortho.pl --geosar=${mergedir}/${master}.geosar --in="${mergedir}/DIF_INT/amp_${master}_${slave}_ml11.r4" --demdesc="${demmerge}" --tag="amp_${master}_${slave}_ml11" --odir="${mergedir}/DIF_INT" --exedir="${EXE_DIR}"  >> "${mergedir}"/ortho_amp.log 2<&1

#geotiff files
cohorthotif="${mergedir}/DIF_INT/coh_${master}_${slave}_ortho.tiff"
cohorthotifrgb="${mergedir}/DIF_INT/coh_${master}_${slave}_ortho.rgb.tiff"
amporthotif="${mergedir}/DIF_INT/amp_${master}_${slave}_ortho.tiff"
amporthotifrgb="${mergedir}/DIF_INT/amp_${master}_${slave}_ortho.rgb.tiff"
phaorthotif="${mergedir}/DIF_INT/pha_${master}_${slave}_ortho.tiff"
phaorthotifrgb="${mergedir}/DIF_INT/pha_${master}_${slave}_ortho.rgb.tiff"
unworthotif="${mergedir}/DIF_INT/unw_${master}_${slave}_ortho.tiff"
unworthotifrgb="${mergedir}/DIF_INT/unw_${master}_${slave}_ortho.rgb.tiff"


#create geotiff results
ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/coh_${master}_${slave}_ml11_ortho.rad" --mask --colortbl=BLACK-WHITE --min=1 --max=255  --demdesc="${demmerge}" --outfile="${cohorthotifrgb}" >> "${mergedir}"/coh_ortho_sw${sw}.log 2<&1

ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/amp_${master}_${slave}_ml11_ortho.rad"  --mask  --alpha="${mergedir}/DIF_INT/coh_${master}_${slave}_ml11_ortho.rad" --min=1 --max=255 --gep  --colortbl=BLACK-WHITE   --demdesc="${demmerge}" --outfile="${amporthotifrgb}" >> "${mergedir}"/amp_ortho_sw${sw}.log 2<&1

ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/psfilt_${master}_${slave}_ml11_ortho.rad" --mask --alpha="${mergedir}/DIF_INT/amp_${master}_${slave}_ml11_ortho.rad"  --demdesc="${demmerge}" --outfile="${phaorthotifrgb}" --colortbl=BLUE-RED  >> "${mergedir}"/pha_ortho_sw${sw}.log 2<&1

ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/psfilt_${master}_${slave}_ml11_ortho.rad"   --demdesc="${demmerge}" --outfile="${phaorthotif}" >> "${mergedir}"/phagrayscale_ortho_sw${sw}.log 2<&1

ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/amp_${master}_${slave}_ml11_ortho.rad" --demdesc="${demmerge}" --outfile="${amporthotif}" >> "${mergedir}"/amp_ortho_sw${sw}.log 2<&1

ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/coh_${master}_${slave}_ml11_ortho.rad" --demdesc="${demmerge}" --outfile="${cohorthotif}" >> "${mergedir}"/coh_ortho_sw${sw}.log 2<&1



#crop output geotiffs if aoi is set
declare -a aoi
#look for an aoi file
local wkid=${_WF_ID}

#copy master and slave id
local masteridfile=`ciop-browseresults -r "${wkid}" -j node_swath | grep -i masterid | grep -i txt | head -1`
if [ -n "${masteridfile}" ]; then
    ciop-copy "hdfs://${masteridfile}" -q -O "${mergedir}"
fi

local slaveidfile=`ciop-browseresults -r "${wkid}" -j node_swath | grep -i slaveid | grep -i txt | head -1`
if [ -n "${masteridfile}" ]; then
    ciop-copy "hdfs://${slaveidfile}" -q -O  "${mergedir}"
fi


#run alt_ambig
mkdir -p "${mergedir}/DAT/"
local ambigdat="${mergedir}/DAT/AMBIG.dat"
setlatlongeosar.pl --geosar="${mergedir}/${master}.geosar"
local orbitmaster=`grep "ORBITAL FILE" "${mergedir}/${master}.geosar" | cut -b 40-1024 | sed 's@^[[:space:]]*@@g;s@[[:space:]]*$@@g'`
local orbitslave=`grep "ORBITAL FILE" "${procdir}/SW${sw}_DEBURST/DAT/GEOSAR/${slave}.geosar" | cut -b 40-1024 | sed 's@^[[:space:]]*@@g;s@[[:space:]]*$@@g'`

echo -e "${orbitmaster}\n${orbitslave}" | alt_ambig.pl --geosar="${mergedir}/${master}.geosar" -o "${ambigdat}" > /dev/null 2<&1

if [ ! -e "${ambigdat}" ]; then
    ciop-log "Info" "Missing AMBIG.dat file"
fi

local altambiginfo=($(grep -E "^[0-9]+" "${ambigdat}" | head -1))
local bperp=""

if [  ${#altambiginfo[@]} -ge 6 ]; then
    bperp=${altambiginfo[4]}
    ciop-log "INFO" "BPERP $bperp"
else
    ciop-log "INFO" "Invalid format for AMBIG.DAT file "
fi


wkt=$(tiff2wkt "`ls ${mergedir}/DIF_INT/pha*.tiff | head -1`")

echo "${wkt}" > ${mergedir}/wkt.txt

#publish results
#ciop-publish -m "${mergedir}/DIF_INT/*.tiff" 
mkdir -p ${procdir}/log 2>/dev/null



#create properties files for each png
create_interf_properties "${amporthotif}" "Interferometric Amplitude" "${mergedir}" "${mergedir}/${master}.geosar" "${procdir}/SW${sw}_DEBURST/DAT/GEOSAR/${slave}.geosar"

create_interf_properties "${phaorthotif}" "Interferometric Phase" "${mergedir}" "${mergedir}/${master}.geosar" "${procdir}/SW${sw}_DEBURST/DAT/GEOSAR/${slave}.geosar"

create_interf_properties "${cohorthotif}" "Interferometric Coherence" "${mergedir}" "${mergedir}/${master}.geosar" "${procdir}/SW${sw}_DEBURST/DAT/GEOSAR/${slave}.geosar"


#unwrap
if [ "${unwrap}" == "true"  ]; then
    ciop-log "INFO"  "Configuring phase unwrapping"
    
    unwmlaz=`echo "${mlaz}*4" | bc -l`
    unwmlran=`echo "${mlran}*4" | bc -l`
    
    interf_sar.pl --master="${mergedir}/${master}.geosar" --slave="${procdir}/SW${sw}_DEBURST/DAT/GEOSAR/${slave}.geosar" --ci2master="${mergedir}/${master}_SLC.ci2"  --ci2slave="${mergedir}/geo_${slave}_${master}.ci2"  --demdesc="${demmerge}" --outdir="${mergedir}/DIF_INT" --exedir="${EXE_DIR}"  --mlaz="${unwmlaz}" --mlran="${unwmlran}" --amp --coh --bort --ran --inc  > "${mergedir}/interf_mlunw.log" 2<&1
    
    snaphucfg="/${mergedir}/snaphu_template.txt"
    cp /opt/diapason/gep.dir/snaphu_template.txt "${snaphucfg}"
    chmod 775 "${snaphucfg}"
    
#compute additionnal parameters passed to snaphu                                                                     
    
#BPERP                                                                                                               
    bortfile=${mergedir}/DIF_INT/bort_${master}_${slave}_ml${unwmlaz}${unwmlran}.r4

    if [ -z "$bperp" ]; then
	bperp=`view_raster.pl --file="${bortfile}" --type=r4 --count=1000 | awk '{v = $1 ; avg += v ;} END { print avg/NR }'`
    fi
    echo "BPERP ${bperp}" >> "${snaphucfg}"
    
    lnspc=`grep "LINE SPACING" "${mergedir}/${master}.geosar" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    colspc=`grep "PIXEL SPACING RANGE" "${mergedir}/${master}.geosar" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    mlslres=`echo "${colspc}*${unwmlran}"  | bc -l`
    mlazres=`echo "${lnspc}*${unwmlaz}"  | bc -l`
    
    echo "RANGERES ${mlslres}" >> "${snaphucfg}"
    echo "AZRES ${mlazres}" >> "${snaphucfg}"
    
    snaphutemp="${mergedir}/saphu_parm"
    
#now write the geosar inferred parameters                                                             
    ${EXE_DIR}/dump_snaphu_params  >  "${snaphutemp}"   <<EOF  
${mergedir}/${master}.geosar
EOF
    
    grep [0-9] "${snaphutemp}" | grep -iv diapason >> "${snaphucfg}"
    
#unwrapped phase
    unwpha="${mergedir}/DIF_INT/unw_${master}_${slave}_ml${unwmlaz}${unwmlran}.r4"
#amplitude
    amp="${mergedir}/DIF_INT/amp_${master}_${slave}_ml${unwmlaz}${unwmlran}.r4"
#coherence     
    coh="${mergedir}/DIF_INT/coh_${master}_${slave}_ml${unwmlaz}${unwmlran}.byt"
    
    echo "OUTFILE ${unwpha}" >> "${snaphucfg}"
    echo "AMPFILE ${amp}" >> "${snaphucfg}"
    echo "CORRFILE ${coh}" >> "${snaphucfg}"
    
    export WDIR="${mergedir}/"

#make a copy of the snaphu configuration as ad_unwrap.sh deletes the file
    
    cfgtemp="${mergedir}/snaphu_configuration.txt"
    
    cp "${snaphucfg}" "${cfgtemp}"
    
    unwrapinput="${mergedir}/DIF_INT/pha_${master}_${slave}_ml${unwmlaz}${unwmlran}.pha"
    unwrapcmd="/opt/diapason/gep.dir/ad_unwrap.sh \"${cfgtemp}\" \"${unwrapinput}\""
    
    ciop-log "INFO"  "Running phase unwrapping"
    cd ${mergedir}/
    touch fcnts.sh
    chmod 775 fcnts.sh
    eval "${unwrapcmd}" > ${mergedir}/unwrap.log 2<&1
    cd -
    if [ -e "${unwpha}" ]; then
	
        #run ortho on unwrapped phase
	ciop-log "INFO"  "Running Unwrapping results ortho-projection"
	ortho.pl --geosar="${mergedir}/${master}.geosar" --real  --mlaz="${unwmlaz}" --mlran="${unwmlran}"  --odir="${mergedir}/DIF_INT" --exedir="${EXE_DIR}" --tag="unw_${master}_${slave}_ml${unwmlaz}${unwmlran}" --in="${unwpha}" --demdesc="${demmerge}"   > "${mergedir}"/ortho_unw.log 2<&1
	ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/unw_${master}_${slave}_ml${unwmlaz}${unwmlran}_ortho.rad" --alpha="${mergedir}/DIF_INT/coh_${master}_${slave}_ml11_ortho.rad" --mask --min=1 --max=255 --colortbl=BLUE-RED  --demdesc="${demmerge}" --outfile="${unworthotifrgb}" >> "${mergedir}"/ortho_unw.log 2<&1
       	
	ortho2geotiff.pl --ortho="${mergedir}/DIF_INT/unw_${master}_${slave}_ml${unwmlaz}${unwmlran}_ortho.rad"   --demdesc="${demmerge}" --outfile="${unworthotif}" >> "${mergedir}"/ortho_unw_grayscale.log 2<&1

	gdaladdo -r average ${unworthotifrgb} 2 4 8
	
	create_interf_properties "${unworthotif}" "Unwrapped Phase" "${mergedir}" "${mergedir}/${master}.geosar" "${procdir}/SW${sw}_DEBURST/DAT/GEOSAR/${slave}.geosar"
	
	
	
    else
	ciop-log "ERROR" "Phase unwrapping failed"
    fi
    
fi

#publish the properties files
ciop-publish -m "${mergedir}/DIF_INT/*.properties"

#publish tiff files
gdaladdo -r average "${cohorthotifrgb}" 2 4 8
gdaladdo -r average "${amporthotifrgb}" 2 4 8
gdaladdo -r average "${phaorthotifrgb}" 2 4 8
	

ciop-publish -m "${mergedir}"/DIF_INT/*.tiff

find ${procdir} -iname "*.log" -exec cp '{}' ${procdir}/log  \;
find ${procdir} -iname "*list*.txt" -exec cp '{}' ${procdir}/log  \;
local logzip="${procdir}/TEMP/logs.zip"
cd "${procdir}"
zip "${logzip}" log/*
# The log.zip publishing has been stopped as requested on DCS-384
# ciop-publish -m "${logzip}"
cd -



return ${SUCCESS}

}

#detect if the processed pair is IW or EW mode
function detect_sensor_mode()
{
    if [ $# -lt 1 ]; then
	return $ERRMISSING
    fi

    local procdir="$1"

    local procmode=`find "${procdir}" -name "*.geosar" -exec grep "^MODE" '{}' \; | cut -b 40-1024 | sed 's@[[:space:]]@@g' | grep "IW\|EW" | head -1`
    
    [ -n "${procmode}" ] && {
	echo "${procmode}"
	return $SUCCESS
    }
    
    return $ERRINVALID
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
#unwrap option
export unwrap=(`ciop-getparam unwrap`)

#check for dems
check_dems ${_WF_ID} || {
    ciop-log "ERROR" "No DEM found"
    exit ${ERRGENERIC}
}


while read data
do

#get the inputs
if [ -z "${data}" ]; then
    break
fi

if [ $count -gt 0 ]; then
    break
fi

for file in `ciop-browseresults -r "${_WF_ID}" -j node_swath | grep -i SAFE`; do
    hadoop dfs -rmr $file > /dev/null 2<&1
done

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
[ $status -ne $SUCCESS ] && {
    procCleanup
    node_cleanup "${_WF_ID}"
    exit ${ERRGENERIC}
}

done

mode=$(detect_sensor_mode "${serverdir}")

MLAZ=2
MLRAN=8

if [ -n "${mode}" ] && [ "${mode}" ==  "EW" ] ; then
    MLRAN=4
fi

ciop-log "INFO" "Merging sub-swaths"
merge_swaths ${master} ${slave} "${serverdir}" "${serverdir}/dem.dat" ${MLAZ} ${MLRAN} "${swath_list}"



let "count += 1"

[ "${nodecleanup}" == "true" ]  && {
    #delete intermediary results 
    nodelist="node_swath node_burst node_coreg node_interf"
    wkid_=${_WF_ID}
    for node in $nodelist ; do
	for d in `ciop-browseresults -r "${wkid_}" -j ${node}`; do
	    hadoop dfs -rmr $d > /dev/null 2<&1
	done
    done
}


procCleanup



done

exit ${SUCCESS}
