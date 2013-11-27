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
PREFIX=current
SUFFIX=png
OUTPUTFORMAT=jpg

function usage {
	echo "Usage: ${SCRIPTNAME} [-a tilesize] [-o jpg|png] [-p prefix] [-s suffix] [-t threads] [-h]" >&2
	cat >&2 <<-EOF
		Parameters:
		-a tilesize  specify output tilesize in pixels (default: ${TILESIZE})
		-o jpg|png   specify output format (default: ${OUTPUTFORMAT})
		-p prefix    specify input image prefix (default: ${PREFIX})
		-s suffix    specify input image suffix (default: ${SUFFIX})
		-t threads   specify how many parallel threads to run (default: ${THREADS})
		-h           show this help

		This script takes images that are tiles of a larger image and creates
		output files suitable for use with OpenSeadragon.

		Example:
		You have four files that make up a bigger image, all sized 50000x50000 px:

		bigimage-0-0.png      bigimage-50000-0.png
		bigimage-0-50000.png  bigimage-50000-50000.png

		To create the tiles and map.xml file from this, you'd run:
		
		${SCRIPTNAME} -p bigimage -s png

		To enable multithreading, output tilesize and explicit output format:

		${SCRIPTNAME} -p bigimage -s png -o jpg -a 256 -t 4
	EOF
	[[ ${#} -eq 1 ]] && exit ${1} || exit ${EXIT_FAILURE}
}

while getopts 'a:o:p:s:t:h' OPTION ; do
	case ${OPTION} in
		a)  TILESIZE=${OPTARG} ;;
		o)  OUTPUTFORMAT=${OPTARG} ;;
		p)  PREFIX=${OPTARG} ;;
		s)  SUFFIX=${OPTARG} ;;
		t)  THREADS=${OPTARG} ;;
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

if ls -U work*${SUFFIX} >/dev/null 2>&1 ; then
	echo "work*${SUFFIX} exists!" >&2
	echo "This script uses work*${OUTPUTFORMAT} files as temporary files." >&2
	echo "Please remove these files and try again:" >&2
	echo work*${SUFFIX}
	exit ${EXIT_ERROR}
fi

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

# checked for this before, but make sure anyway.
rm -f work*${SUFFIX}
src="${PREFIX}" # will be set to "work" after first iteration

for level in $( seq ${startLevel} -1 0 ) ; do
	echo "Level: ${level}"
	resized=0

	if [ ! -f "work.${SUFFIX}" -a ${level} -lt ${startLevel} ] ; then # do not resize on first iteration
		echo "Resizing ${src}-*-*.${SUFFIX} ..."
		THREAD_CMDS=""
		for pic in ${src}-*-*.${SUFFIX} ; do
			cmd="$(mktemp)"
			cat >${cmd} <<-EOF
				SECONDS=0
				convert ${pic} -resize 50% "work-${pic#${src}-}"
				echo "- Resized ${pic} in \${SECONDS}s"
			EOF
			THREAD_CMDS="${THREAD_CMDS} ${cmd}"
		done
		echo ${THREAD_CMDS} | tr ' ' '\n' | xargs -P${THREADS} -n1 /bin/bash
		rm -f ${THREAD_CMDS}
		echo "done"
		resized=1
		src="work"

		echo "Montaging ... "
		THREAD_CMDS=""
		for x in $( seq 0 $((${INPUTTILESIZE}*${MONTAGESTEP}*2)) ${maxx} ); do
			for y in $( seq 0 $((${INPUTTILESIZE}*${MONTAGESTEP}*2)) ${maxy} ); do
				tl="work-${x}-${y}.${SUFFIX}"
				tr="work-$((${x}+(${INPUTTILESIZE}*${MONTAGESTEP})))-${y}.${SUFFIX}"
				bl="work-${x}-$((${y}+(${INPUTTILESIZE}*${MONTAGESTEP}))).${SUFFIX}"
				br="work-$((${x}+(${INPUTTILESIZE}*${MONTAGESTEP})))-$((${y}+(${INPUTTILESIZE}*${MONTAGESTEP}))).${SUFFIX}"
				output="work-${x}-${y}.${SUFFIX}"
				read tlw tlh < <( identify -format "%w %h" ${tl} )
				cmd="$(mktemp)"
				echo "SECONDS=0" > ${cmd}
				echo -n "convert xc:black -page +0+0 ${tl}" >> ${cmd}
				[ -f "${tr}" ] && echo -n " -page +${tlw}+0 ${tr}" >> ${cmd}
				[ -f "${bl}" ] && echo -n " -page +0+${tlh} ${bl}" >> ${cmd}
				[ -f "${br}" ] && echo -n " -page +${tlw}+${tlh} ${br}" >> ${cmd}
				echo " -layers merge +repage ${output}" >> ${cmd}
				${cmd}
				echo "echo \"- Montaged ${output} in \${SECONDS}s\"" >> ${cmd}
				delme=""
				delme="${delme} ${tl} ${tr} ${bl} ${br}"
				delme="${delme//${output}/}"
				echo "rm -f ${delme}" >> ${cmd}
				THREAD_CMDS="${THREAD_CMDS} ${cmd}"
			done
		done
		echo ${THREAD_CMDS} | tr ' ' '\n' | xargs -P${THREADS} -n1 /bin/bash
		rm -f ${THREAD_CMDS}
		MONTAGESTEP=$((${MONTAGESTEP}*2))
		echo "done"

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
			echo " done in \${SECONDS}s"
		fi

		echo -n "Cropping work.${SUFFIX} ..."
		SECONDS=0
		convert work.${SUFFIX} -crop ${TILESIZE}x${TILESIZE} -set filename:tile "%[fx:page.x/${TILESIZE}]_%[fx:page.y/${TILESIZE}]" map_files/${level}/%[filename:tile].${OUTPUTFORMAT}
		echo " done in \${SECONDS}s"
	else
		echo "Cropping ${src}-*-*.${SUFFIX} ..."
		read w h < <( identify -format "%w %h" ${src}-0-0.${SUFFIX} )
		w=$((${w}/${TILESIZE}))
		h=$((${h}/${TILESIZE}))
		THREAD_CMDS=""
		for pic in ${src}-*-*.${SUFFIX} ; do
			x=${pic#${src}-}
			x=${x%-*}
			x=$((((${x}/(${MONTAGESTEP}))/${INPUTTILESIZE})*${w}))

			y=${pic%.${SUFFIX}}
			y=${y##*-}
			y=$((((${y}/(${MONTAGESTEP}))/${INPUTTILESIZE})*${h}))

			cmd="$(mktemp)"
			cat > ${cmd} <<-EOF
				SECONDS=0
				convert ${pic} -crop ${TILESIZE}x${TILESIZE} -set filename:tile "%[fx:page.x/${TILESIZE}+${x}]_%[fx:page.y/${TILESIZE}+${y}]" map_files/${level}/%[filename:tile].${OUTPUTFORMAT}
				echo "- Cropped ${pic}+${x}+${y} in \${SECONDS}s"
			EOF
			THREAD_CMDS="${THREAD_CMDS} ${cmd}"
		done
		echo ${THREAD_CMDS} | tr ' ' '\n' | xargs -P${THREADS} -n1 /bin/bash
		rm -f ${THREAD_CMDS}
		echo " done"
	fi
done 
