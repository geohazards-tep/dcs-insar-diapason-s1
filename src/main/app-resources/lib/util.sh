#!/bin/bash


# define the exit codes                                                                                                             
SUCCESS=0
ERRGENERIC=1
ERRPERM=2
ERRSTGIN=3
ERRINVALID=4
ERRSTARTDATE=5
ERRSTOPDATE=6
ERRMISSING=255

function procdirectory()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi

    rootdir="$1"

    directory=`mktemp -d ${rootdir}/DIAPASON_XXXXXX` || {
	return ${ERRPERM}
    }

    mkdir -p ${directory}/{DAT/GEOSAR,RAW_C5B,SLC_CI2,ORB,TEMP,log,QC,GRID,DIF_INT,CD,GEO_CI2,VOR} || {
	return ${ERRPERM}
    }
    
    echo "${directory}"
    
    return ${SUCCESS}
}

function procCleanup()
{
    if [ -n "${serverdir}"  ] && [ -d "$serverdir" ]; then
        ciop-log "INFO : Cleaning up processing directory ${serverdir}"
        rm -rf "${serverdir}"
    fi

}

function node_cleanup()
{
    if [  $# -lt 1 ]; then
	return ${ERRGENERIC}
    fi
    local wkfid="$1"
    local nodelist="node_swath node_burst node_coreg node_interf"
    for node in $nodelist ; do
	for d in `ciop-browseresults -r "${wkfid}" -j ${node}`; do
	    hadoop dfs -rmr $d > /dev/null 2<&1
	done
    done
}

function product_name_parse()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi
    
    product=`basename "$1"`
    info=(`echo ${product%.*} | sed 's@_@ @g'`)
    echo "${info[@]}"

if [ ${#info[@]} -lt 3 ]; then
    #ciop-log "ERROR" "Bad Filename : ${product}"
    return ${ERRGENERIC}
    fi
}

function product_check()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi
    
    product=`basename "$1"`
    
    if [ -z "${product}" ]; then
	return ${ERRMISSING}
    fi
    
    #file name should be of the form S1A_(IW|EW)_SLC__1SDH_20150512T022514_20150512T022624_005882_007938_BA47.SAFE
    arr=($(product_name_parse "${product}"))
    
    if [ ${#arr[@]} -lt 3 ]; then
	echo "invalid file name ${product} "${arr[@]}
	return ${ERRINVALID}
    fi
    
    #topsar modes supported
    mode=${arr[1]}
    
    modeok=0
    case $mode in
	IW)modeok=1;;
	EW)modeok=1;;
	*)modeok=0;
esac
    
    if [ $modeok -le 0 ]; then
    #ciop-log "ERROR" "invalid or unsupported mode ${mode}"
	echo "invalid or unsupported mode ${mode}" 1>&2
	return ${ERRINVALID}
    fi

#SLC supported , RAW data unsupported
level=${arr[2]}

if [ "$level" != "SLC" ]; then
    #ciop-log "ERROR" "invalid or unsupported processing level $level"
    echo "invalid or unsupported processing level $level" 1>&2
    return ${ERRINVALID}
fi

return ${SUCCESS}
}


function ref_check()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi

    #input should be a catalogue reference
    local inref="$1"

    #only support sentinel data
    local platform=`opensearch-client -m EOP "${inref}" platform | sed 's@[[:space:]]*@@g'`
    
    if [[ ! "${platform}" =~ ^S1[A-Z] ]]; then
	ciop-log "ERROR" "invalid or unsupported platform ${platform}"
	return ${ERRINVALID}
    fi

    #product should be SLC
    local level=`opensearch-client -m EOP "${inref}" productType | sed 's@[[:space:]]*@@g'`
    
    if [ "${level}" != "SLC" ]; then
	ciop-log "ERROR" "invalid or unsupported processing level $level" 
	return ${ERRINVALID}
    fi

    #data acquisition mode should be IW or EW
    local acqmode=`opensearch-client -m EOP "${inref}" operationalMode | sed 's@[[:space:]]*@@g'`
    if [[ ! "${acqmode}" =~ IW|EW ]]; then
	ciop-log "ERROR" "Acquisition Mode ${acqmode} not supported"
	return ${ERRINVALID}
    fi

    return $SUCCESS
}


get_data() {                                                                                                                                                     
  local ref=$1                                                                                                                                                   
  local target=$2                                                                                                                                                
  local local_file                                                                                                                                               
  local enclosure                                                                                                                                                
  local res                                                                                                                                                      
                                                                                                                                                                 
  [ "${ref:0:4}" == "file" ] || [ "${ref:0:1}" == "/" ] && enclosure=${ref}                                                                                      
                                                                                                                                                                 
  [ -z "$enclosure" ] && enclosure=$( opensearch-client  -f atom  "${ref}" enclosure )                                                                                     
  res=$?                                                                                                                                                         
  enclosure=$( echo ${enclosure} | tail -1 )                                                                                                                     
  [ $res -eq 0 ] && [ -z "${enclosure}" ] && return ${ERR_GETDATA}                                                                                               
  [ $res -ne 0 ] && enclosure=${ref}                                                                                                                             
                                                                                                                                                                 
  local_file="$( echo ${enclosure} | ciop-copy -f -U -O ${target} - 2> /dev/null )"                                                                              
  res=$?                                                                                                                                                         
  [ ${res} -ne 0 ] && return ${res}                                                                                                                              
  echo ${local_file}                                                                                                                                             
}               


function matching_bursts
{
    if [ $# -lt 5 ]; then
	echo "$FUNCNAME geosar1 geosar2 varstart varstop varlist" 1>&2
	return 1
    fi

    local geosarm="$1"
    local geosars="$2"

    if [ -z "${EXE_DIR}"  ] || [ ! -e "${EXE_DIR}/matching_burst" ]; then
	return 2
    fi
    
    local first=""
    local last=""
    local list=()
    
      #master bursts to test
    local starting=0
    local ending=50
    
    #in case use set an aoi
    local aoi=""
    if [ $# -ge 6 ]; then
	aoi="$6"
   
	if [ "`type -t s1_bursts_aoi`"  = "function" ] && [ -n "${aoi}" ]; then
	    #echo "running s1_swaths_aoi"
	    s1_bursts_aoi "${geosarm}" "${aoi}" bursts
	    status=$?
	    #echo "s1_burst_aoi status $status"
	    if [ $status -eq 0 ]; then
		local burstlist=(`echo "$bursts"`)
		if [ ${#burstlist[@]} -eq 2 ]; then
		    starting=${burstlist[0]}
		    ending=${burstlist[1]}
		fi
	    else 	
		#subswath does not intersect with the specified aoi
		return 3
	    fi
	    
	fi
	
    fi

    for x in `seq "${starting}" "${ending}"`; do
	bursts=`${EXE_DIR}/matching_burst "${geosarm}" "${geosars}" "${x}" 2>/dev/null | grep -i slave | sed 's@\([^=]*\)\(=\)\(.*\)@\3@g' `
	status=$?

	if [ $status -ne 0 ] || [ -z "${bursts}" ]; then
	        continue
		fi
	
	if [ $bursts -lt  0 ]; then
	        continue
		fi
	
	if [ -z "${first}" ]; then
	        first=$x
		fi
	
	last=$x
	
	list=( ${list[@]} $bursts ) 
	
    done
    
    if [ -z "${first}" ] || [ -z "${last}" ]; then
	return 3
    fi
 
    nbursts=`echo "${last} - ${first} +1" | bc -l`
    nlistbursts=${#list[@]}
    
    if [ $nlistbursts -ne ${nbursts} ]; then
	return 4
    fi
    
     eval "$3=\"${first}\""
     eval "$4=\"${last}\""
     eval "$5=\"${list[@]}\""

    return 0
}



function get_POEORB() {
  local S1_ref=$1
  local aux_dest=$2

  [ -z "${aux_dest}" ] && aux_dest="." 

  local startdate
  local enddate
  
  startdate="$( opensearch-client "${S1_ref}" startdate)" 
  enddate="$( opensearch-client "${S1_ref}" enddate)" 
  
  [ -z "${startdate}"  ] && {
      return ${ERRSTARTDATE}
  }

  [ -z "${enddate}"  ] && {
      return ${ERRSTOPDATE}
  }
  echo "start : ${startdate}"
  echo "end : ${enddate}"
  

  #aux_list=$( opensearch-client  "http://data.terradue.com/gs/catalogue/aux/gtfeature/search?q=AUX_POEORB&start=${startdate}&stop=${enddate}" enclosure )
  aux_list=$( opensearch-client  "https://catalog.terradue.com/sentinel1-aux/search?pt=POEORB&start=${startdate}&stop=${stopdate}&do=terradue" enclosure)
  
  ciop-log "INFO" "aux orbit list : ${aux_list}"
  
  [ -z "${aux_list}" ] && return 1

  echo ${aux_list} | ciop-copy -o ${aux_dest} -

}



# dem download 
function get_DEM()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi
    
    #check for required programs 
    if [ -z "`type -p curl`" ] ; then
	ciop-log "ERROR : System missing curl utility" return
	${ERRMISSING} 
    fi
	
    if [ -z "`type -p gdalinfo`" ] ; then
	ciop-log "ERROR : System missing gdalinfo utility" return
	${ERRMISSING} 
    fi


    procdir="$1"
    
    
    latitudes=(`grep -h LATI ${procdir}/DAT/GEOSAR/*.geosar | cut -b 40-1024 | grep [0-9] | sort -n |  sed -n '1p;$p' | sed 's@[[:space:]]@@g' | tr '\n' ' ' `)
    longitudes=(`grep -h LONGI ${procdir}/DAT/GEOSAR/*.geosar | cut -b 40-1024 | grep [0-9] | sort -n | sed -n '1p;$p' | sed 's@[[:space:]]@@g' | tr '\n' ' ' `)
    
    if [ ${#latitudes[@]} -lt 2 ]; then
	return ${ERRGENERIC}
    fi
    
    if [ ${#longitudes[@]} -lt 2 ]; then
	return ${ERRGENERIC}
    fi
    
    url="http://dedibox.tre-altamira.com/demdownload?lat="${latitudes[0]}"&lat="${latitudes[1]}"&lon="${longitudes[0]}"&lon="${longitudes[1]}
    
    ciop-log "INFO : Downloading DEM from ${url}"
    
    demtif=${procdir}/DAT/dem.tif
    
    downloadcmd="curl -o \"${demtif}\" \"${url}\" "

    eval "${downloadcmd}" > "${procdir}"/log/demdownload.log 2<&1

    #check downloaded file
    if [ ! -e "${demtif}" ]; then
	ciop-log "ERROR : Unable to download DEM data"
	return ${ERRGENERIC}
    fi
    
    #check it is a tiff
    gdalinfo "${demtif}" > /dev/null 2<&1 || {
	ciop-log "ERROR : No DEM data over selected area"
	return ${ERRGENERIC}
    }
    
    
return ${SUCCESS}

}


#inputs :
# geosar file  , aoi (shapefile,or aoi string),
#output : variable for storing burst lists
function s1_bursts_aoi()
{
	if [ $# -lt 3 ]; then
		return 1
	fi
	
	local geosar=$1
	local aoi=$2
	
	if [ -z "${EXE_DIR}" ]; then
		return 1
	fi	
	
	if [ ! -e "${EXE_DIR}/swath_aoi_intersect" ]; then
		echo "missing binary ${EXE_DIR}/swath_aoi_intersect"
		return 1
	fi
	
	local bursts_=$(${EXE_DIR}/swath_aoi_intersect "${geosar}" "$aoi" | grep BURST | sed 's@[^0-9]@@g')
	
	if [ -z "${bursts_}" ]; then
		return 1
	fi
	
	#record output burst list
	eval  "$3=\"${bursts_}\""
	
	return 0
}


function create_interf_properties()
{
    if [ $# -lt 4 ]; then
	echo "$FUNCNAME : usage:$FUNCNAME file description serverdir geosar"
	return 1
    fi

    local inputfile=$1
    local fbase=`basename ${inputfile}`
    local description=$2
    local serverdir=$3
    local geosarm=$4
    local geosars=""
    if [ $# -ge 5 ]; then
    geosars=$5
    fi
    
    local datestart=$(geosar_time "${geosarm}")
    
    local dateend=""
    if [ -n "$geosars" ]; then
	dateend=$(geosar_time "${geosars}")
    fi

    local propfile="${inputfile}.properties"
    echo "title = DIAPASON InSAR Sentinel-1 TOPSAR(IW,EW) - ${description} - ${datestart} ${dateend}" > "${propfile}"
    echo "Description = ${description}" >> "${propfile}"
    echo "date = ${datestart}/${dateend} " >> "${propfile}"
    local sensor=`grep -h "SENSOR NAME" "${geosarm}" | cut -b 40-1024 | awk '{print $1}'`
    echo "Sensor\ Name = ${sensor}" >> "${propfile}"
    local masterid=`head -1 ${serverdir}/masterid.txt`
    if [ -n "${masterid}" ]; then
	echo "Master\ SLC\ Product = ${masterid}" >> "${propfile}"
    fi 
    local slaveid=`head -1 ${serverdir}/slaveid.txt`
    if [ -n "${slaveid}" ]; then
	echo "Slave\ SLC\ Product = ${slaveid}" >> "${propfile}"
    fi 

    #look for 2jd utility to convert julian dates
    if [ -n "`type -p j2d`"  ] && [ -n "${geosars}" ]; then
	local jul1=`grep -h JULIAN "${geosarm}" | cut -b 40-1024 | sed 's@[^0-9]@@g'`
	local jul2=`grep -h JULIAN "${geosars}" | cut -b 40-1024 | sed 's@[^0-9]@@g'`
	if [ -n "${jul1}"  ] && [ -n "${jul2}" ]; then 
	
	    local dates=""
	    for jul in `echo -e "${jul1}\n${jul2}" | sort -n`; do
		local julday=`echo "2433283+${jul}" | bc -l`
		local dt=`j2d ${julday} | awk '{print $1}'`
		
		dates="${dates} ${dt}"
	    done
	   
	fi
	echo "Observation\ Dates = $dates" >> "${propfile}"
	
	local timeseparation=`echo "$jul1 - $jul2" | bc -l`
	if [ $timeseparation -lt 0 ]; then
	    timeseparation=`echo "$timeseparation*-1" | bc -l`
	fi
	
	if [ -n "$timeseparation" ]; then
	    echo "Time\ Separation\ \(days\) = ${timeseparation}" >> "${propfile}"
	fi
    fi

    local altambig="${serverdir}/DAT/AMBIG.dat"
    if [ -e "${altambig}" ] ; then
	local info=($(grep -E "^[0-9]+" "${altambig}" | head -1))
	if [  ${#info[@]} -ge 6 ]; then
	    #write incidence angle
	    echo "Incidence\ angle\ \(degrees\) = "${info[2]} >> "${propfile}"
	    #write baseline
	    local bas=`echo ${info[4]} | awk '{ if($1>=0) {print $1} else { print $1*-1} }'`
	    echo "Baseline\ \(meters\) = ${bas}" >> "${propfile}"
	else
	    ciop-log "INFO" "Invalid format for AMBIG.DAT file "
	fi
    else
	ciop-log "INFO" "Missing AMBIG.DAT file in ${serverdir}/DAT"
    fi 
    
    local satpass=`grep -h "SATELLITE PASS" "${geosarm}"  | cut -b 40-1024 | awk '{print $1}'`
    
    if [ -n "${satpass}" ]; then
	echo "Orbit\ Direction = ${satpass}" >> "${propfile}"
    fi

    local publishdate=`date +'%B %d %Y' `
    echo "Processing\ Date  = ${publishdate}" >> "${propfile}"
    
    local logfile=`ls ${serverdir}/ortho_amp.log`
    if [ -e "${logfile}" ]; then
	local resolution=`grep "du mnt" "${logfile}" | cut -b 15-1024 | sed 's@[^0-9\.]@\n@g' | grep [0-9] | sort -n | tail -1`
	if [ -n "${resolution}" ]; then
	    echo "Resolution\ \(meters\) = ${resolution}" >> "${propfile}"
	fi
    fi
    
    local wktfile="${serverdir}/wkt.txt"
    
    if [ -e "${wktfile}" ]; then
	local wkt=`head -1 "${wktfile}"`
	echo "geometry = ${wkt}" >> "${propfile}"
    fi
}


function download_dem_from_ref()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "$FUNCNAME:ref directory "
	return ${ERRMISSING}
    fi

    local ref="$1"
    local outputdir="$2"

    #look for the extent of the scene
    local wkt=($(opensearch-client -f atom "$ref" wkt | sed 's@[a-zA-Z()]@@g' | sed 's@,@ @g'))
    
    if [ -z  "${wkt}" ]; then
	ciop-log "ERROR " "Missing wkt info for ref $ref"
	return ${MISSING}
    fi

    
    local lon
    local lat

    lon=(`echo "${wkt[@]}" | sed 's@ @\n@g' | sed -n '1~2p' | sort -n | sed -n '1p;$p' | sed 's@\n@ @g'`)
    lat=(`echo "${wkt[@]}" | sed 's@ @\n@g' | sed -n '2~2p' | sort -n | sed -n '1p;$p' | sed 's@\n@ @g'`)

    if [ ${#lon[@]} -ne 2 ] || [ ${#lat[@]} -ne 2 ]; then
	ciop-log "ERROR" "Bad format for wkt description"
	return ${ERRINVALID}
    fi

    
    
    local demurl="http://dedibox.tre-altamira.com/demdownload?lat="${lat[0]}"&lat="${lat[1]}"&lon="${lon[0]}"&lon="${lon[1]}
    
    ciop-log "INFO " "Downloading DEM from ${demurl}"
    
    
    local demtif=${outputdir}/dem.tif
    
    local downloadcmd="curl -o \"${demtif}\" \"${demurl}\" "
    
    eval "${downloadcmd}" > "${outputdir}"//demdownload.log 2<&1

    #check downloaded file
    if [ ! -e "${demtif}" ]; then
	ciop-log "ERROR" "Unable to download DEM data"
	return ${ERRGENERIC}
    fi

    #check it is a tiff
    gdalinfo "${demtif}" > /dev/null 2<&1 || {
	ciop-log "ERROR" "No DEM data over selected area"
	return ${ERRGENERIC}
    }

    return ${SUCCESS}
}


# create a shapefile from a bounding box string
# arguments:
# bounding box string of the form "minlon,minlat,maxlon,maxlat"
# output diretory where shapefile shall be created
# tag used to name the shapefile
function aoi2shp()
{
    if [ $# -lt 3 ]; then
	ciop-log "ERROR" "Usage:$FUNCTION minlon,minlat,maxlon,maxlat directory tag"
	return ${ERRMISSING}
    fi

    local aoi="$1"

    local directory="$2"

    local tag="$3"

    if [ ! -d "`readlink -f $directory`" ]; then
	ciop-log "ERROR" "$FUNCTION:$directory is not a directory"
	return ${ERRINVALID}
    fi

    #check for aoi validity
    local aoiarr=(`echo ${aoi} | sed 's@,@ @g' `)

    local nvalues=${#aoiarr[@]}

    if [ $nvalues -lt 4 ]; then
	ciop-log "ERROR" "$FUNCTION:Invalid aoi :$aoi"
	ciop-log "ERROR" "$FUNCTION:Should be of the form: minlon,minlat,maxlon,maxlat"
	return ${ERRINVALID}
    fi

    #use a variable for each
    local maxlon=${aoiarr[2]}
    local maxlat=${aoiarr[3]}
    local minlon=${aoiarr[0]}
    local minlat=${aoiarr[1]}

    #check for shapelib utilities
    if [ -z "`type -p shpcreate`" ]; then
	ciop-log "ERROR" "Missing shpcreate utility"
	return ${ERRMISSING}
    fi

    if [ -z "`type -p shpadd`" ]; then
	ciop-log "ERROR" "Missing shpadd utility"
	return ${ERRMISSING}
    fi

    #enter the output shapefile directory
    cd "${directory}" || {
	ciop-log "ERROR" "$FUNCTION:No permissions to access ${directory}"
	cd -
	return ${ERRPERM}
}
    

    #create empty shapefile
    shpcreate "${tag}" polygon
    local statuscreat=$?

    if [ ${statuscreat}  -ne 0 ]; then
	cd -
	ciop-log "ERROR" "$FUNCTION:Shapefile creation failed"
	return ${ERRGENERIC}
    fi 

    shpadd "${tag}" "${minlon}" "${minlat}" "${maxlon}" "${minlat}" "${maxlon}" "${maxlat}"  "${minlon}" "${maxlat}" "${minlon}" "${minlat}"
    
    local statusadd=$?

    if [ ${statusadd} -ne 0 ]; then
	ciop-log "ERROR" "$FUNCTION:Failed to add polygon to shapefile"
	return ${ERRGENERIC}
    fi
    
  local shp=${directory}/${tag}.shp

  if [ ! -e "${shp}" ]; then
      cd -
      ciop-log "ERROR" "$FUNCTION:Failed to create shapefile"
      return ${ERRGENERIC}
  fi

  echo "${shp}"

  return ${SUCCESS}

 }


# check the intersection between 2 products
# arguments:
# ref1 ref2 catalogue references to each product 
#return 0 if products intersect , non zero otherwise
function product_intersect()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "$FUNCNAME:ref1 ref2"
	return 255
    fi

    local ref1="$1"
    local ref2="$2"
    
        #look for the extent of the scene
    local wkt1=($(opensearch-client -f atom "$ref1" wkt ))
    local wkt2=($(opensearch-client -f atom "$ref2" wkt ))

    n1=${#wkt1[@]}
    n2=${#wkt2[@]}

    #if wkt info is missing for at least
    # 1 product , cannot check intersection
    # assume it is ok
    if [ $n1 -eq 0 ] || [ $n2 -eq 0 ]; then
	 ciop-log "INFO" "Missing wkt info"
	return 0
    fi

    polygon_intersect wkt1[@]} wkt2[@]}
    
    status=$?

    return $status
}

# check the intersection between 2 polygons
# arguments:
# 2 arrays with polygon geometry definitions
# call: polygon_intersect wkt1[@] wkt2[@] 
#return 0 if products intersect , non zero otherwise
function polygon_intersect()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "$FUNCNAME:poly1 poly2"
	return 255
    fi

    declare -a wkt1=("${!1}")
    declare -a wkt2=("${!2}")
    
    
    /usr/bin/python - <<END
import sys
try:
  from osgeo import ogr
except ImportError:
  sys.exit(0)

wkt1="${wkt1[@]}"
wkt2="${wkt2[@]}"

status=0
  
try:
# Create spatial reference
  out_srs = ogr.osr.SpatialReference()
  out_srs.ImportFromEPSG(4326)

  poly1 = ogr.CreateGeometryFromWkt(wkt1)
  poly1.AssignSpatialReference(out_srs)
  poly2 = ogr.CreateGeometryFromWkt(wkt2)
  poly2.AssignSpatialReference(out_srs)

  intersection=poly2.Intersection(poly1)

  if intersection.IsEmpty():
     status=1
except Exception,e:
  sys.exit(0)

sys.exit( status )

END
local status=$?

if [ $status -ne 0 ]; then
    return 1
fi

}

# get suitable minimum and maximum image
# values for histogram stretching
# arguments:
# input image
# variable used to store minimum value
# variable used to store maximum value
# return 0 if successful , non-zero otherwise
function image_equalize_range()
{
    if [ $# -lt 1 ]; then
	return 255
    fi 

    #check gdalinfo is available
    if [ -z "`type -p gdalinfo`" ]; then
	return 1
    fi

    local image="$1"

    
    declare -A Stats
    
    #load the statistics information from gdalinfo into an associative array
    while read data ; do
	string=$(echo ${data} | awk '{print "Stats[\""$1"\"]=\""$2"\""}')
	eval "$string"
    done < <(gdalinfo -hist "${image}"   | grep STATISTICS | sed 's@STATISTICS_@@g;s@=@ @g')

    #check that we have mean and standard deviation
    local mean=${Stats["MEAN"]}
    local stddev=${Stats["STDDEV"]}
    local datamin=${Stats["MINIMUM"]}

    if [ -z "$mean"   ] || [ -z "${stddev}" ] || [ -z "${datamin}" ]; then
	return 1
    fi 
    
   
    local min=`echo $mean - 3*${stddev} | bc -l`
    local max=`echo $mean + 3*${stddev} | bc -l`
    
    local below_zero=`echo "$min < $datamin" | bc -l`
    
    [ ${below_zero} -gt 0 ] && {
	min=$datamin
    }
    
    if [ $# -ge 2 ]; then
	eval "$2=${min}"
    fi

    if [ $# -ge 3 ]; then
	eval "$3=${max}"
    fi

   
    return 0
}

function geosar_time()
{
    if [ $# -lt 1 ]; then
	return $ERRMISSING
    fi
    local geosar="$1"
    
    local date=$(/usr/bin/perl <<EOF
use POSIX;
use strict;
use esaTime;
use geosar;

my \$geosar=geosar->new(FILE=>'$geosar');
my \$time=\$geosar->startTime();
print \$time->xgr;
EOF
)

    [ -z "$date" ] && {
	return $ERRMISSING
    }

    echo $date
    return 0
}


function tiff2wkt(){
    
    if [ $# -lt 1 ]; then
	echo "Usage $0 geotiff"
	return $ERRMISSING
    fi
    
    tiff="$1"
    
    declare -a upper_left
    upper_left=(`gdalinfo $tiff | grep "Upper Left" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)
    
    
    declare -a lower_left
    lower_left=(`gdalinfo $tiff | grep "Lower Left" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)

    declare -a lower_right
    lower_right=(`gdalinfo $tiff | grep "Lower Right" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)
    
    
    declare -a upper_right
    upper_right=(`gdalinfo $tiff | grep "Upper Right" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)
    
    echo "POLYGON((${upper_left[0]} ${upper_left[1]} , ${lower_left[0]} ${lower_left[1]},  ${lower_right[0]} ${lower_right[1]} , ${upper_right[0]} ${upper_right[1]}, ${upper_left[0]} ${upper_left[1]}))"
   
    return 0
}



function download_dem_from_aoi()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "$FUNCNAME:ref directory "
	return ${ERRMISSING}
    fi

    local aoistring="$1"
    local outputdir="$2"
    
    
        #check for aoi validity
    local aoiarr=(`echo ${aoistring} | sed 's@,@ @g' `)
    
    local nvalues=${#aoiarr[@]}
    
    if [ $nvalues -lt 4 ]; then
	ciop-log "ERROR" "$FUNCTION:Invalid aoi :$aoi"
	ciop-log "ERROR" "$FUNCTION:Should be of the form: minlon,minlat,maxlon,maxlat"
	return ${ERRINVALID}
    fi

    #use a variable for each
    local maxlon=${aoiarr[2]}
    local maxlat=${aoiarr[3]}
    local minlon=${aoiarr[0]}
    local minlat=${aoiarr[1]}

    
    local demurl="http://dedibox.tre-altamira.com/demdownload?lat="${minlat}"&lat="${maxlat}"&lon="${maxlon}"&lon="${minlon}
    
    ciop-log "INFO " "Downloading DEM from ${demurl}"
    
    
    local demtif=${outputdir}/dem.tif
    
    local downloadcmd="curl -o \"${demtif}\" \"${demurl}\" " > /dev/null 2<&1
    
    eval "${downloadcmd}" > "${outputdir}"//demdownload.log 2<&1

    #check downloaded file
    if [ ! -e "${demtif}" ]; then
	ciop-log "ERROR" "Unable to download DEM data"
	return ${ERRGENERIC}
    fi

    #check it is a tiff
    gdalinfo "${demtif}" > /dev/null 2<&1 || {
	ciop-log "ERROR" "No DEM data over selected area"
	return ${ERRGENERIC}
    }

    #resample
    local tmpdem=${outputdir}/tempo.tif
    
    gdalwarp -tr 0.000416666666500 -0.000416666666500 -te ${minlon} ${minlat} ${maxlon} ${maxlat}  -ot Int16 -r bilinear ${demtif} ${tmpdem} || {
	ciop-log "ERROR" "Failed to resample DEM"
	return ${ERRGENERIC}
    }
    
    mv ${tmpdem} ${demtif}

    return ${SUCCESS}
}
