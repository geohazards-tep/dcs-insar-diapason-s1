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



get_data() {                                                                                                                                                     
  local ref=$1                                                                                                                                                   
  local target=$2                                                                                                                                                
  local local_file                                                                                                                                               
  local enclosure                                                                                                                                                
  local res                                                                                                                                                      
                                                                                                                                                                 
  [ "${ref:0:4}" == "file" ] || [ "${ref:0:1}" == "/" ] && enclosure=${ref}                                                                                      
                                                                                                                                                                 
  [ -z "$enclosure" ] && enclosure=$( opensearch-client "${ref}" enclosure )                                                                                     
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

    for x in `seq 0 50`; do
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
  

  aux_list=$( opensearch-client  "http://data.terradue.com/gs/catalogue/aux/gtfeature/search?q=AUX_POEORB&start=${startdate}&stop=${enddate}" enclosure )

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
    
    url="http://www.altamira-information.com/demdownload?lat="${latitudes[0]}"&lat="${latitudes[1]}"&lon="${longitudes[0]}"&lon="${longitudes[1]}
    
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