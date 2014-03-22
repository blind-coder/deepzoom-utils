#!/bin/bash

. functions.inc.sh

trap "kill 0" SIGINT SIGTERM EXIT # kill all subshells on exit
trap "kill -STOP 0" SIGSTOP
trap "kill -CONT 0" SIGCONT

export MAGICK_TEMPORARY_PATH=.
tileSize=512
startLevel=19
level=${startLevel}
THREADS=1

echo "Level: ${level}"
echo -n "Cropping ..."
if [ -d map_files/${level} ] ; then
	echo " map_files/${level} exists ... skipping ..."
else
	for THREAD in $( seq 0 $((${THREADS}-1)) ) ; do (
		export MAGICK_MEMORY_LIMIT=6GB
		numPic=0
		for pic in current-*-*.png ; do
			numPic=$((${numPic}+1))
			[ $(( ${numPic} % ${THREADS} )) -eq ${THREAD} ] || continue

			x=${pic#current-}
			x=${x%-*}
			y=${pic%.png}
			y=${y##*-}
			x=$((${x}/${tileSize}))
			y=$((${y}/${tileSize}))

			mkdir -p map_files/${level}
			SECONDS=0
			convert ${pic} -crop ${tileSize}x${tileSize} -set filename:tile "%[fx:page.x/${tileSize}+${x}]_%[fx:page.y/${tileSize}+${y}]" map_files/${level}/%[filename:tile].jpg
			echo -n " T:${THREAD} ${pic}(${SECONDS}s)"
		done ) &
	done
	wait
	echo " ... done"
fi

rm -f work.png
src="current" # set to "work" after first iteration
for level in $( seq $(( ${startLevel}-1 )) -1 0 ) ; do
	echo "Level: ${level}"

	read w h < <( identify -format "%w %h" ${src}-0-0.png )

	if [ ${w} -le 12800 ] ; then
		if [ ! -f work.png ] ; then
			echo -n "Resizing ..."
			for THREAD in $( seq 0 $((${THREADS}-1)) ) ; do (
				export MAGICK_MEMORY_LIMIT=6GB
				numPic=0
					for pic in ${src}-*-*.png ; do
					numPic=$((${numPic}+1))
					[ $(( ${numPic} % ${THREADS} )) -eq ${THREAD} ] || continue
					SECONDS=0
					convert ${pic} -resize 50% "work-${pic#${src}-}" ;
					echo -n " T:${THREAD} ${pic}(${SECONDS}s)"
				done ) &
			done
			wait
			echo " ... done"
			read w h < <( identify -format "%w %h" ${src}-0-0.png )

			echo -n "Montaging ..."
			SECONDS=0
			export MAGICK_MEMORY_LIMIT=4GB
			montage \
				work-0-0.png      work-25600-0.png      work-51200-0.png      work-76800-0.png      work-102400-0.png      work-128000-0.png      work-153600-0.png      work-179200-0.png      work-204800-0.png      work-230400-0.png      work-256000-0.png \
				work-0-25600.png  work-25600-25600.png  work-51200-25600.png  work-76800-25600.png  work-102400-25600.png  work-128000-25600.png  work-153600-25600.png  work-179200-25600.png  work-204800-25600.png  work-230400-25600.png  work-256000-25600.png \
				work-0-51200.png  work-25600-51200.png  work-51200-51200.png  work-76800-51200.png  work-102400-51200.png  work-128000-51200.png  work-153600-51200.png  work-179200-51200.png  work-204800-51200.png  work-230400-51200.png  work-256000-51200.png \
				work-0-76800.png  work-25600-76800.png  work-51200-76800.png  work-76800-76800.png  work-102400-76800.png  work-128000-76800.png  work-153600-76800.png  work-179200-76800.png  work-204800-76800.png  work-230400-76800.png  work-256000-76800.png \
				work-0-102400.png work-25600-102400.png work-51200-102400.png work-76800-102400.png work-102400-102400.png work-128000-102400.png work-153600-102400.png work-179200-102400.png work-204800-102400.png work-230400-102400.png work-256000-102400.png \
				work-0-128000.png work-25600-128000.png work-51200-128000.png work-76800-128000.png work-102400-128000.png work-128000-128000.png work-153600-128000.png work-179200-128000.png work-204800-128000.png work-230400-128000.png work-256000-128000.png \
				-geometry ${w}x${h}+0+0 \
				-tile 11x6 \
				work.png
				cp -v work.png offlinemap.png
			echo " done in ${SECONDS}s"
		else # work.png exists from previous iteration
			echo -n "Resizing ..."
			SECONDS=0
			export MAGICK_MEMORY_LIMIT=6GB
			convert work.png -resize 50% work.png
			echo " done in ${SECONDS}s"
		fi
		
		echo -n "Cropping ..."
		[ -d map_files/${level} ] && echo -e "\tmap_files/${level} exists ... skipping ..." && continue
		mkdir -p map_files/${level}
		SECONDS=0
		export MAGICK_MEMORY_LIMIT=6GB
		convert work.png -crop ${tileSize}x${tileSize} -set filename:tile "%[fx:page.x/${tileSize}]_%[fx:page.y/${tileSize}]" map_files/${level}/%[filename:tile].jpg
		echo " done in ${SECONDS}s"

	else # ${w} > 12800
		
		echo -n "Resizing ..."
		for THREAD in $( seq 0 $((${THREADS}-1)) ) ; do (
			numPic=0
			for pic in ${src}-*-*.png ; do
				numPic=$((${numPic}+1))
				[ $(( ${numPic} % ${THREADS} )) -eq ${THREAD} ] || continue
				SECONDS=0
				convert ${pic} -resize 50% "work-${pic#${src}-}" ;
				echo -n " T:${THREAD} ${pic}"
				echo -n "(${SECONDS}s)"
			done ) &
		done
		wait
		echo " ... done"
		src="work"

		[ -d map_files/${level} ] && echo -e "\tmap_files/${level} exists ... skipping ..." && continue
		mkdir -p map_files/${level}

		echo -n "Cropping ..."
		read w h < <( identify -format "%w %h" work-0-0.png )
		w=$((${w}/${tileSize}))
		h=$((${h}/${tileSize}))
		for THREAD in $( seq 0 $((${THREADS}-1)) ) ; do (
			numPic=0
			for pic in work-*-*.png ; do
				numPic=$((${numPic}+1))
				[ $(( ${numPic} % ${THREADS} )) -eq ${THREAD} ] || continue
				x=${pic#work-}
				x=${x%-*}
				x=$(((${x}/25600)*${w}))

				y=${pic%.png}
				y=${y##*-}
				y=$(((${y}/25600)*${h}))

				SECONDS=0
				convert ${pic} -crop ${tileSize}x${tileSize} -set filename:tile "%[fx:page.x/${tileSize}+${x}]_%[fx:page.y/${tileSize}+${y}]" map_files/${level}/%[filename:tile].jpg
				echo -n " T:${THREAD} ${pic}+${x}+${y}(${SECONDS}s)"
			done ) &
		done
		wait
		echo " ... done"
	fi
done
read w h < <( identify -format "%w %h" current-0-0.png )

maxx=0
maxy=0
for pic in current-*-*.png ; do
	x=${pic#current-}
	x=${x%-*}
	y=${pic%.png}
	y=${y##*-}
	[ ${x} -gt ${maxx} ] && maxx=${x}
	[ ${y} -gt ${maxy} ] && maxy=${y}
done
maxx=$((${maxx}+${w}))
maxy=$((${maxy}+${h}))
cat > map.xml <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<Image TileSize='${tileSize}'
	Overlap='0'
	Format='jpg'
	xmlns='http://schemas.microsoft.com/deepzoom/2008'>
	<Size Width='${maxx}' Height='${maxy}'/>
</Image>
EOF

createOverlaysJSON
