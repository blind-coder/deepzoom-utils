#!/bin/bash
# Script:	deepzoom.sh
# Task:	Script to create tiles suitable for a deepzoom tool like openseadragon.

# global variables
SCRIPTNAME=$(basename ${0} .sh)

EXIT_SUCCESS=0
EXIT_FAILURE=1
EXIT_ERROR=2
EXIT_BUG=10

# variables for option switches with default values
MAGICK_TEMPORARY_PATH=.
TILESIZE=512
MONTAGESTEP=1
THREADS=1
VERBOSE=n
PREFIX=current
SUFFIX=png
OUTPUTFORMAT=jpg

while getopts 'a:o:p:s:t:vh' OPTION ; do
	case ${OPTION} in
		a)  TILESIZE=${OPTARG} ;;
		o)  OUTPUTFORMAT=${OPTARG} ;;
		p)  PREFIX=${OPTARG} ;;
		s)  SUFFIX=${OPTARG} ;;
		t)  THREADS=${OPTARG} ;;
		v)	VERBOSE=y ;;
		h)	usage ${EXIT_SUCCESS} ;;
		\?)	echo "unknown option \"-${OPTARG}\"." >&2
			usage ${EXIT_ERROR}
			;;
		:)	echo "option \"-${OPTARG}\" requires an argument." >&2
			usage ${EXIT_ERROR}
			;;
		*)	echo "Impossible error. parameter: ${OPTION}" >&2
			usage ${EXIT_BUG}
			;;
	esac
done

# skip parsed options
shift $(( OPTIND - 1 ))

if [ -f "work.${OUTPUTFORMAT}" ]; then
	echo "work.${OUTPUTFORMAT} exists!" >&2
	echo "This script uses work*.${OUTPUTFORMAT} files as temporary files." >&2
	echo "Please remove these files and try again." >&2
	exit ${EXIT_ERROR}
fi

. functions.inc.sh

trap "kill 0" SIGINT SIGTERM EXIT # kill all subshells on exit
trap "kill -STOP 0" SIGSTOP
trap "kill -CONT 0" SIGCONT

read w h < <( identify -format "%w %h" ${PREFIX}-0-0.${SUFFIX} )
if [ "${w}" != "${h}" ]; then
	echo "Image ${PREFIX}-0-0.${SUFFIX} is not SQUARE (${w}x${h})!" >&2
	echo "This is not supported, and I will exit now. Bye!" >&2
	exit ${EXIT_ERROR}
fi
INPUTTILESIZE=${w}

# Calculate maximum dimensions for map.xml file
maxx=0
maxy=0
for pic in ${PREFIX}-*-*.${SUFFIX} ; do
	x=${pic#${PREFIX}-}
	x=${x%-*}
	y=${pic%.${SUFFIX}}
	y=${y##*-}
	[ ${x} -gt ${maxx} ] && maxx=${x}
	[ ${y} -gt ${maxy} ] && maxy=${y}
done

cat > map.xml <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<Image TileSize='${TILESIZE}'
	Overlap='0'
	Format='${OUTPUTFORMAT}'
	xmlns='http://schemas.microsoft.com/deepzoom/2008'>
	<Size Width='$((${maxx}+${w}))' Height='$((${maxy}+${h}))'/>
</Image>
EOF

# calculate necessary levels
# levels = ceil(log(max(width, height)) / log(2))
BC_CEIL='define ceil(x) { auto savescale; savescale = scale; scale = 0; if (x>0) { if (x%1>0) result = x+(1-(x%1)) else result = x } else result = -1*floor(-1*x);  scale = savescale; return result }'
[ ${maxx} -gt ${maxy} ] && i=${maxx} || i=${maxy}
read startLevel < <( echo -e "${BC_CEIL}\nceil(l(${i})/l(2))" | bc -l | sed -e 's,\..*$,,' )

rm -f work.${SUFFIX}
src="${PREFIX}" # set to "work" after first iteration

for level in $( seq ${startLevel} -1 0 ) ; do
	echo "Level: ${level}"
	resized=0

	if [ ! -f "work.${SUFFIX}" -a ${level} -lt ${startLevel} ] ; then # do not resize on first iteration
		echo -n "Resizing ${src}-*-*.${SUFFIX} ..."
		for THREAD in $( seq 0 $((${THREADS}-1)) ) ; do (
			numPic=0
			for pic in ${src}-*-*.${SUFFIX} ; do
				numPic=$((${numPic}+1))
				[ $(( ${numPic} % ${THREADS} )) -eq ${THREAD} ] || continue
				SECONDS=0
				convert ${pic} -resize 50% "work-${pic#${src}-}"
				echo -n " T:${THREAD} ${pic}(${SECONDS}s)"
			done ) &
		done
		wait
		echo " done"
		resized=1
		src="work"

		echo -n "Montaging ... "
		SECONDS=0
		delme=""
		for x in $( seq 0 $((${INPUTTILESIZE}*${MONTAGESTEP}*2)) ${maxx} ); do
			for y in $( seq 0 $((${INPUTTILESIZE}*${MONTAGESTEP}*2)) ${maxy} ); do
				tl="work-${x}-${y}.${SUFFIX}"
				tr="work-$((${x}+(${INPUTTILESIZE}*${MONTAGESTEP})))-${y}.${SUFFIX}"
				bl="work-${x}-$((${y}+(${INPUTTILESIZE}*${MONTAGESTEP}))).${SUFFIX}"
				br="work-$((${x}+(${INPUTTILESIZE}*${MONTAGESTEP})))-$((${y}+(${INPUTTILESIZE}*${MONTAGESTEP}))).${SUFFIX}"
				output="work-${x}-${y}.${SUFFIX}"
				read tlw tlh < <( identify -format "%w %h" ${tl} )
				cmd="convert xc:black -page +0+0 ${tl}"
				[ -f "${tr}" ] && cmd="${cmd} -page +${tlw}+0 ${tr}"
				[ -f "${bl}" ] && cmd="${cmd} -page +0+${tlh} ${bl}"
				[ -f "${br}" ] && cmd="${cmd} -page +${tlw}+${tlh} ${br}"
				cmd="${cmd} -layers merge +repage ${output}"
				SECONDS=0
				${cmd}
				echo -n "${output} (${SECONDS}s) "
				delme="${delme} ${tl} ${tr} ${bl} ${br}"
				delme="${delme//${output}/}"
			done
		done
		MONTAGESTEP=$((${MONTAGESTEP}*2))
		rm -f ${delme}
		echo " done"

		numWorks=0
		for x in work-*-*.${SUFFIX} ; do
			numWorks=$((${numWorks}+1))
		done
		if [ ${numWorks} -eq 1 ] ; then
			mv work-0-0.${SUFFIX} work.${SUFFIX}
		fi
	fi

	[ -d map_files/${level} ] && echo -e "\tmap_files/${level} exists ... skipping ..." && continue
	mkdir -p map_files/${level}

	if [ -f work.${SUFFIX} ] ; then
		if [ ${resized} -eq 0 ] ; then
			echo -n "Resizing work.${SUFFIX} ..."
			SECONDS=0
			convert work.${SUFFIX} -resize 50% work.${SUFFIX}
			echo " done in ${SECONDS}s"
		fi

		echo -n "Cropping work.${SUFFIX} ..."
		SECONDS=0
		convert work.${SUFFIX} -crop ${TILESIZE}x${TILESIZE} -set filename:tile "%[fx:page.x/${TILESIZE}]_%[fx:page.y/${TILESIZE}]" map_files/${level}/%[filename:tile].${OUTPUTFORMAT}
		echo " done in ${SECONDS}s"
	else
		echo -n "Cropping ${src}-*-*.${SUFFIX} ... "
		read w h < <( identify -format "%w %h" ${src}-0-0.${SUFFIX} )
		w=$((${w}/${TILESIZE}))
		h=$((${h}/${TILESIZE}))
		for THREAD in $( seq 0 $((${THREADS}-1)) ) ; do (
			numPic=0
			for pic in ${src}-*-*.${SUFFIX} ; do
				numPic=$((${numPic}+1))
				[ $(( ${numPic} % ${THREADS} )) -eq ${THREAD} ] || continue
				x=${pic#${src}-}
				x=${x%-*}
				x=$((((${x}/(${MONTAGESTEP}))/${INPUTTILESIZE})*${w}))

				y=${pic%.${SUFFIX}}
				y=${y##*-}
				y=$((((${y}/(${MONTAGESTEP}))/${INPUTTILESIZE})*${h}))

				SECONDS=0
				convert ${pic} -crop ${TILESIZE}x${TILESIZE} -set filename:tile "%[fx:page.x/${TILESIZE}+${x}]_%[fx:page.y/${TILESIZE}+${y}]" map_files/${level}/%[filename:tile].${OUTPUTFORMAT}
				echo -n " T:${THREAD} ${pic}+${x}+${y}(${SECONDS}s)"
			done ) &
		done
		wait
		echo " done"
	fi
done 
createOverlaysJSON
