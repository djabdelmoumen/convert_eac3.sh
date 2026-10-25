#!/bin/bash
#set -x

clear

# Fichier de log:
log_file="/tmp/ffmpeg_execution.log"
> "$log_file" # Vider le fichier log a chaque debut du script.
function logtofile
{
	local message="$1";
	echo -e "$(date +"[%d %B %T]") $message" | tee -a "$log_file";
}

logtofile "SCRIPT DE CONVERSION DU CODEC AUDIO EAC3"
logtofile "fichier de log: \"$log_file\""

# Vérifier si FFmpeg et FFprobe sont installés
if ! command -v ffmpeg &> /dev/null || ! command -v ffprobe &> /dev/null
then
	logtofile "ERREUR : FFmpeg et/ou FFprobe ne sont pas installés ou ne sont pas dans le PATH."
    exit 1
fi

logtofile "FFmpeg et/ou FFprobe sont bien installés."

# Vérifier si un fichier vidéo a été fourni en argument
if [ -z "$1" ]; then
	logtofile "Pas de fichier passer en argument."
    logtofile "Usage : $0 <chemin_vers_le_fichier_video> [repertoire_de_sortie]"
    exit 1
fi

# Configuration Section:

ffmpeg="ffmpeg"
logtofile "Utilisation de $ffmpeg"

# choix des codec a utiliser:
codec_video_function="Copy_video"       ; logtofile "codec_video_function: Copy_video";
codec_audio_function="transcode_eac3"   ; logtofile "codec_audio_function: transcode_eac3"
codec_subtitle_function="copy_subtitle" ; logtofile "codec_subtitle_function: copy_subtitle"

INPUT_FILE=$(echo "$1" | tr -d '\r\n') # Nettoyer les arguments d'éventuels retours à la ligne ou espaces parasites
# Extraire le nom de base du fichier sans l'extension
FILENAME_BASE=$(basename -- "$INPUT_FILE")
FILENAME_BASE="${FILENAME_BASE%.*}"
logtofile "le nom de base du fichier à convertir sans l'extension: \"$FILENAME_BASE\""

# Utiliser le deuxième argument s'il est fourni, sinon /tmp/converted par défaut
OUTPUT_DIR=$(echo "${2:-/tmp/converted}" | tr -d '\r\n') # Nettoyer les arguments d'éventuels retours à la ligne ou espaces parasites

# Créer le répertoire de sortie
mkdir -p "$OUTPUT_DIR"
logtofile "Repertoire du media converti: \"$OUTPUT_DIR\""
logtofile "fichier source: \"$INPUT_FILE\""

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++#
audio_is_eac3()
{
    local track_number="$1"  # Numéro de la piste audio (0, 1, etc.)
    local video_file="$2"    # Chemin vers la vidéo

    if [ -z "$track_number" ]; then
        logtofile  "Erreur : Numéro de piste manquante en parametre"
        return 1
    fi
	
	if [ -z "$video_file" ]; then
		logtofile "Erreur dans la fonction audio_is_eac3: fichier vidéo manquant en parametre"
		return 1
	fi

    if [ ! -f "$video_file" ]; then
        logtofile   "Erreur : Le fichier '$video_file' n'existe pas"
        return 1
    fi

    codec=$(ffprobe -v error -select_streams a:"$track_number" -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null)

    if [ "$codec" = "eac3" ]; then
        echo "yes"
    else
        echo "no"
    fi
}

function transcode_eac3
{
	logtofile " \"transcode_eac3\" function is called"

	local audio_tracks=$(ffprobe -v error -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" 2>/dev/null | grep -c "audio")

	if [ "$audio_tracks" -eq 0 ]; then
		logtofile "Aucune piste audio détectée dans '$INPUT_FILE'"
		exit 1
	fi

	logtofile "$audio_tracks pistes audio ont été trouvées."

	audio_map=""
	audio_cmd=" -ac 2 -ar 48000 "
	for ((i=0; i<audio_tracks; i++));
	do
		audio_map=" $audio_map -map 0:a:$i "
		
		if [ "$(audio_is_eac3 "$i" "$INPUT_FILE")" = "yes" ]; then
			 logtofile "Piste $i : E-AC3 détecté. Conversion en AAC stéréo..."
			 audio_cmd=" $audio_cmd -c:a:$i aac -b:a 128k "
		else
			 logtofile "Piste $i : Non E-AC3. Copie sans transcodage..."
			 audio_cmd=" $audio_cmd -c:a:$i copy"
		fi
	done
	
	logtofile "audio_map: $audio_map"
	logtofile "audio_cmd: $audio_cmd"
}

function copy_subtitle
{
	logtofile "copy_subtitle function is called:"
	subtitle_tracks=$(ffprobe -v error -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" 2>/dev/null | grep -c "subtitle")

    if [ "$subtitle_tracks" -eq 0 ]; then
        logtofile "Aucune piste de sous-titre n'a été détectée dans '$INPUT_FILE'. On continue sans sous-titres."
        subtitle_map=""
        subtitle_cmd=""
        return 0
    fi

	logtofile "Nombres de sous-titre : $subtitle_tracks pistes."

	subtitle_map=""
	subtitle_cmd=""
	for ((i=0; i<subtitle_tracks; i++));
	do
		subtitle_map="$subtitle_map -map 0:s:$i"
		subtitle_cmd="$subtitle_cmd -c:s:$i copy"
	done

	logtofile "subtitle_cmd: $subtitle_cmd"
}

function HEVC_plus_pad
{
	logtofile "HEVC_plus_pad is Called"
	video_cmd=" -c:v libx265 -crf 22 -preset slow -profile:v main -level 4.1 -pix_fmt yuv420p \
                              -vf \"scale=1280:-2:force_original_aspect_ratio=decrease,pad=1280:720:(1280-iw)/2:(720-ih)/2:black\" \
                              -x265-params ctu=32:ref=5:bframes=3:b-adapt=2:rc-lookahead=60:vbv-maxrate=10000:vbv-bufsize=10000:qpmax=69:weightp=1:merange=24:chroma-qp-offset=-1:psy-rd=1.0:psy-rdoq=0.15:min-keyint=23 "

	video_map=" -map 0:v:0 "
	logtofile "video parameters: \n $video_cmd"
}

function Copy_video
{
	logtofile "Copy_video function is called"
	video_cmd=" -c:v copy "
	video_map=" -map 0:v:0 "
	logtofile "video parameters: $video_cmd"
}

##---------------------------------------------------------------------- Encoding Function ---------------------------------------------------------------------------##
execute_ffmpeg ()
{
	logtofile "Function: execute_ffmpeg"
	
	$codec_video_function
	$codec_audio_function
	$codec_subtitle_function
	
	ffmpeg_cmd="$ffmpeg -threads 4 -hide_banner -loglevel verbose -i \"$INPUT_FILE\" \
				$video_map $audio_map $subtitle_map $video_cmd $audio_cmd $subtitle_cmd -movflags +faststart \"$OUTPUT_DIR/$FILENAME_BASE.mkv\""
	
	logtofile "ffmpeg_cmd:\n$ffmpeg_cmd"
	
	start_time=$(date +%s)
	start_date=$(date)
	
	logtofile "Début de l'encodage à $start_date..."
	eval "$ffmpeg_cmd"
	exit_code=$?
	
	end_time=$(date +%s)
	end_date=$(date)
	
	duration=$((end_time - start_time))
	hours=$((duration / 3600))
	minutes=$(( (duration % 3600) / 60))
	seconds=$((duration % 60))
	
	logtofile "Encodage terminé à $end_date."
	logtofile "Temps d'exécution : $hours heures, $minutes minutes, $seconds secondes"

	if [ $exit_code -eq 0 ]; then
		logtofile "FFmpeg s'est exécuté avec succès."
	else
		logtofile "Erreur lors de l'exécution de FFmpeg (code de sortie : $exit_code)."
	fi
	
	exit
}

execute_ffmpeg