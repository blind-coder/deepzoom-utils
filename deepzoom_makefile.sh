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
		-T path      specify the path where temporary files are held (default: ${MAGICK_TEMPORARY_PATH})
		             Warning, these can grow very large! Do not use anything on / or /tmp!
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

		PATH: ${PATH}
	EOF
	[[ ${#} -eq 1 ]] && exit ${1} || exit ${EXIT_FAILURE}
}

while getopts 'a:o:p:s:t:T:h' OPTION ; do
	case ${OPTION} in
		a)  TILESIZE=${OPTARG} ;;
		o)  OUTPUTFORMAT=${OPTARG} ;;
		p)  PREFIX=${OPTARG} ;;
		s)  SUFFIX=${OPTARG} ;;
		t)  THREADS=${OPTARG} ;;
		T)	MAGICK_TEMPORARY_PATH="${OPTARG}" ;;
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

trap "kill 0; exit" SIGINT SIGTERM EXIT # kill all subshells on exit
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
#BC_CEIL="define ceil(x) { if (x>0) { if (x%1>0) return x+(1-(x%1)) else return x } else return -1*floor(-1*x) }\n"
BC_FLOOR="define floor(x) { if (x>0) return x-(x%1) else return -1*ceil(-1*x) }"
[ $((${maxx}+${w})) -gt $((${maxy}+${h})) ] && i=$((${maxx}+${w})) || i=$((${maxy}+${h}))
read startLevel < <( echo -e "${BC_FLOOR}\n${BC_CEIL}\nceil(l(${i})/l(2))" | bc -l | sed -e 's,\..*$,,' )

# checked for this before, but make sure anyway.
src="${PREFIX}" # will be set to "work" after first iteration

rm -f Makefile
echo -n "all: " >> Makefile
for x in $( seq ${startLevel} -1 0 ); do
	echo -n "map_files/${x}/crop.done " >> Makefile
done

echo >> Makefile
echo >> Makefile

tmpdir="$(mktemp -d)"
for file in ${prefix}*; do
	touch "${tmpdir}/${file}"
done

for level in $( seq ${startLevel} -1 0 ) ; do
	mkdir -p map_files/${level}

	if [ ${level} -lt ${startLevel} ] ; then
		echo -n "map_files/${level}/resize.done: " >> Makefile
		for pic in ${tmpdir}/${src}-*-*.${SUFFIX} ; do
			t="${pic#${tmpdir}/${src}-}"
			t="${t%.${SUFFIX}}"
			read x y <<< "${t//-/ }"
			echo -n "map_files/${level}/resize-${x}-${y}.done " >> Makefile
			echo "map_files/${level}/resize-${x}-${y}.done:" >> "${tmpdir}/Makefile.append"
			echo -e "\tconvert ${pic#${tmpdir}/} -resize 50% 'work-${pic#*${src}-}'" >> "${tmpdir}/Makefile.append"
			echo -e "\ttouch map_files/${level}/resize-${x}-${y}.done" >> "${tmpdir}/Makefile.append"
			echo >> "${tmpdir}/Makefile.append"
			touch "${tmpdir}/work-${pic#*${src}-}"
		done
		echo >> Makefile
		echo -e "\ttouch map_files/${level}/resize-${x}-${y}.done" >> Makefile
		echo >> Makefile
		cat "${tmpdir}/Makefile.append" >> Makefile
		rm -f "${tmpdir}/Makefile.append"

		src="work"

		echo -n "map_files/${level}/montage.done: " >> Makefile
		echo -n "map_files/${level}/resize.done " >> Makefile
		for x in $( seq 0 $((${INPUTTILESIZE}*${MONTAGESTEP}*2)) ${maxx} ); do
			for y in $( seq 0 $((${INPUTTILESIZE}*${MONTAGESTEP}*2)) ${maxy} ); do
				echo -n "map_files/${level}/montage-${x}-${y}.done " >> Makefile
				echo "map_files/${level}/montage-${x}-${y}.done:" >> "${tmpdir}/Makefile.append"

				tl="work-${x}-${y}.${SUFFIX}"
				tr="work-$((${x}+(${INPUTTILESIZE}*${MONTAGESTEP})))-${y}.${SUFFIX}"
				bl="work-${x}-$((${y}+(${INPUTTILESIZE}*${MONTAGESTEP}))).${SUFFIX}"
				br="work-$((${x}+(${INPUTTILESIZE}*${MONTAGESTEP})))-$((${y}+(${INPUTTILESIZE}*${MONTAGESTEP}))).${SUFFIX}"
				output="work-${x}-${y}.${SUFFIX}"
				
				echo -en "\tbash -c 'read tlw tlh < <( identify -format \"%w %h\" ${tl} ); convert xc:transparent -background transparent -page +0+0 ${tl} " >> "${tmpdir}/Makefile.append"
				echo -n "\` [ -f '${tr}' ] && echo -n \" -page +\$\${tlw}+0 ${tr} \" \` " >> "${tmpdir}/Makefile.append"
				echo -n "\` [ -f '${bl}' ] && echo -n \" -page +0+\$\${tlh} ${bl} \" \` " >> "${tmpdir}/Makefile.append"
				echo -n "\` [ -f '${br}' ] && echo -n \" -page +\$\${tlw}+\$\${tlh} ${br} \" \` " >> "${tmpdir}/Makefile.append"
				echo " -layers merge +repage ${output}'" >> "${tmpdir}/Makefile.append"
				delme=""
				delme="${delme} ${tl} ${tr} ${bl} ${br}"
				delme="${delme//${output}/}"
				echo -e "\trm -f ${delme}" >> "${tmpdir}/Makefile.append"
				echo -e "\ttouch map_files/${level}/montage-${x}-${y}.done" >> "${tmpdir}/Makefile.append"
				echo >> "${tmpdir}/Makefile.append"

				for d in ${delme}; do
					rm -f "${tmpdir}/${d}"
				done
			done
		done
		echo >> Makefile
		echo -e "\ttouch map_files/${level}/montage.done" >> Makefile
		echo >> Makefile
		cat "${tmpdir}/Makefile.append" >> Makefile
		rm -f "${tmpdir}/Makefile.append"

		MONTAGESTEP=$((${MONTAGESTEP}*2))
	fi

	echo >> Makefile
	echo -n "map_files/${level}/crop.done: " >> Makefile

	if [ ${level} -lt ${startLevel} ] ; then # do not resize on first iteration
		echo -n "map_files/${level}/montage.done " >> Makefile
		echo -n "map_files/$((${level}+1))/crop.done " >> Makefile
	fi
	# read w h < <( identify -format "%w %h" ${src}-0-0.${SUFFIX} )
	# w=$((${w}/${TILESIZE}))
	# h=$((${h}/${TILESIZE}))
	for pic in ${tmpdir}/${src}-*-*.${SUFFIX}; do
		t="${pic#${tmpdir}/${src}-}"
		t="${t%.${SUFFIX}}"
		read x y <<< "${t//-/ }"
		x=$(((${x}/${MONTAGESTEP})/${INPUTTILESIZE}))
		y=$(((${y}/${MONTAGESTEP})/${INPUTTILESIZE}))
		
		echo -n "map_files/${level}/crop-${x}-${y}.done " >> Makefile
		echo "map_files/${level}/crop-${x}-${y}.done:" >> "${tmpdir}/Makefile.append"
		echo -en "\tbash -xc '" >> "${tmpdir}/Makefile.append"
		echo -en "read w h < <( identify -format \"%w %h\" \"${pic#${tmpdir}/}\" );" >> "${tmpdir}/Makefile.append"
		echo -en "w=\$\$((\$\${w}/${TILESIZE})); " >> "${tmpdir}/Makefile.append"
		echo -en "h=\$\$((\$\${h}/${TILESIZE})); " >> "${tmpdir}/Makefile.append"
		echo -en "convert '${pic#${tmpdir}/}' -transparent black -crop " >> "${tmpdir}/Makefile.append"
		echo -en "${TILESIZE}x${TILESIZE} -set filename:tile " >> "${tmpdir}/Makefile.append"
		echo -en "\"%[fx:page.x/${TILESIZE}+\$\$((${x}*\$\${w}))]_%[fx:page.y/${TILESIZE}+\$\$((${y}*\$\${h}))]\" " >> "${tmpdir}/Makefile.append"
		echo -e  "map_files/${level}/%[filename:tile].${OUTPUTFORMAT}'" >> "${tmpdir}/Makefile.append"
		echo -e "\ttouch map_files/${level}/crop-${x}-${y}.done" >> "${tmpdir}/Makefile.append"
		echo >> "${tmpdir}/Makefile.append"
	done
	echo >> Makefile
	echo -e "\ttouch map_files/${level}/crop.done" >> Makefile
	echo >> Makefile
	cat "${tmpdir}/Makefile.append" >> "Makefile"
	rm -f "${tmpdir}/Makefile.append"

	#if [ -f work.${SUFFIX} ] ; then
		#if [ ${resized} -eq 0 ] ; then
			#echo -n "Resizing work.${SUFFIX} ..."
			#SECONDS=0
			#convert work.${SUFFIX} -resize 50% work.${SUFFIX}
			#echo " done in ${SECONDS}s"
		#fi
#
		#echo -n "Cropping work.${SUFFIX} ..."
		#SECONDS=0
		#convert work.${SUFFIX} -transparent black -crop ${TILESIZE}x${TILESIZE} -set filename:tile "%[fx:page.x/${TILESIZE}]_%[fx:page.y/${TILESIZE}]" map_files/${level}/%[filename:tile].${OUTPUTFORMAT}
		#echo " done in ${SECONDS}s"
	#fi
done 

rm -r "${tmpdir}"
