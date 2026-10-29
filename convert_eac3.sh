#!/bin/bash
#set -x

clear

# Fichier de log
log_file="/tmp/ffmpeg_execution.log"
> "$log_file"

logtofile()
{
    local message="$1"
    printf '[%s] %s\n' "$(date '+%d %B %T')" "$message" | tee -a "$log_file"
}

logtofile "SCRIPT DE CONVERSION DU CODEC AUDIO EAC3"
logtofile "Fichier de log : \"$log_file\""

# Vérifier si FFmpeg et FFprobe sont installés
if ! command -v ffmpeg >/dev/null 2>&1 ||
   ! command -v ffprobe >/dev/null 2>&1; then
    logtofile "ERREUR : FFmpeg et/ou FFprobe ne sont pas installés ou absents du PATH."
    exit 1
fi

logtofile "FFmpeg et FFprobe sont bien installés."

# Vérifier si un fichier vidéo a été fourni
if [ -z "$1" ]; then
    logtofile "Aucun fichier passé en argument."
    logtofile "Usage : $0 <chemin_vers_le_fichier_video> [repertoire_de_sortie]"
    exit 1
fi

# Configuration
ffmpeg="ffmpeg"
logtofile "Utilisation de $ffmpeg"

# Choix des fonctions de traitement
codec_video_function="Copy_video"
codec_audio_function="transcode_eac3"
codec_subtitle_function="copy_subtitle"

INPUT_FILE="$1"
OUTPUT_DIR="${2:-/tmp/converted}"

# Extraire le nom du fichier sans son extension
FILENAME_BASE=$(basename -- "$INPUT_FILE")
FILENAME_BASE="${FILENAME_BASE%.*}"

# Vérifier le fichier source
if [ ! -f "$INPUT_FILE" ]; then
    logtofile "ERREUR : le fichier source n'existe pas : $INPUT_FILE"
    exit 1
fi

# Créer le répertoire de sortie
if ! mkdir -p -- "$OUTPUT_DIR"; then
    logtofile "ERREUR : impossible de créer le répertoire de sortie."
    exit 1
fi

OUTPUT_FILE="$OUTPUT_DIR/$FILENAME_BASE.mkv"

logtofile "Nom du fichier sans extension : \"$FILENAME_BASE\""
logtofile "Répertoire de sortie : \"$OUTPUT_DIR\""
logtofile "Fichier source : \"$INPUT_FILE\""
logtofile "Fichier de sortie : \"$OUTPUT_FILE\""

# -------------------------------------------------------------------
# Déterminer si une piste audio utilise le codec E-AC3
# -------------------------------------------------------------------
audio_is_eac3()
{
    local track_number="$1"
    local video_file="$2"
    local codec

    if [ -z "$track_number" ] || [ -z "$video_file" ]; then
        logtofile "ERREUR : paramètres manquants dans audio_is_eac3."
        return 1
    fi

    if [ ! -f "$video_file" ]; then
        logtofile "ERREUR : fichier vidéo introuvable : $video_file"
        return 1
    fi

    codec=$(ffprobe -v error \
        -select_streams "a:$track_number" \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$video_file" 2>/dev/null)

    if [ "$codec" = "eac3" ]; then
        echo "yes"
    else
        echo "no"
    fi
}

# -------------------------------------------------------------------
# Transcoder les pistes E-AC3 en AAC stéréo
# Copier les autres pistes audio sans transcodage
# -------------------------------------------------------------------
transcode_eac3()
{
    logtofile "Fonction transcode_eac3 appelée."

    local audio_tracks
    local i
    local codec_status

    audio_tracks=$(ffprobe -v error \
        -show_entries stream=codec_type \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT_FILE" 2>/dev/null | grep -c "audio")

    if [ "$audio_tracks" -eq 0 ]; then
        logtofile "Aucune piste audio détectée dans '$INPUT_FILE'."
        return 1
    fi

    logtofile "$audio_tracks piste(s) audio détectée(s)."

    # Tableaux Bash contenant les arguments FFmpeg
    audio_map=()
    audio_cmd=()

    for ((i=0; i<audio_tracks; i++)); do

        audio_map+=(-map "0:a:$i")

        codec_status=$(audio_is_eac3 "$i" "$INPUT_FILE")

        if [ "$codec_status" = "yes" ]; then
            logtofile "Piste audio $i : E-AC3 détecté, conversion en AAC stéréo."

            audio_cmd+=(
                "-c:a:$i" aac
                "-b:a:$i" 128k
                "-ac:a:$i" 2
                "-ar:a:$i" 48000
            )
        else
            logtofile "Piste audio $i : autre codec, copie sans transcodage."

            audio_cmd+=("-c:a:$i" copy)
        fi
    done

    logtofile "Nombre de pistes audio configurées : $audio_tracks"
}

# -------------------------------------------------------------------
# Copier les pistes de sous-titres
# -------------------------------------------------------------------
copy_subtitle()
{
    logtofile "Fonction copy_subtitle appelée."

    local subtitle_tracks
    local i

    subtitle_tracks=$(ffprobe -v error \
        -show_entries stream=codec_type \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT_FILE" 2>/dev/null | grep -c "subtitle")

    subtitle_map=()
    subtitle_cmd=()

    if [ "$subtitle_tracks" -eq 0 ]; then
        logtofile "Aucune piste de sous-titres détectée."
        return 0
    fi

    logtofile "$subtitle_tracks piste(s) de sous-titres détectée(s)."

    for ((i=0; i<subtitle_tracks; i++)); do
        subtitle_map+=(-map "0:s:$i")
        subtitle_cmd+=("-c:s:$i" copy)
    done
}

# -------------------------------------------------------------------
# Encoder la vidéo en HEVC avec redimensionnement et padding
# -------------------------------------------------------------------
HEVC_plus_pad()
{
    logtofile "Fonction HEVC_plus_pad appelée."

    video_cmd=(
        -c:v libx265
        -crf 22
        -preset slow
        -profile:v main
        -level:v 4.1
        -pix_fmt yuv420p
        -vf "scale=1280:-2:force_original_aspect_ratio=decrease,pad=1280:720:(1280-iw)/2:(720-ih)/2:black"
        -x265-params "ctu=32:ref=5:bframes=3:b-adapt=2:rc-lookahead=60:vbv-maxrate=10000:vbv-bufsize=10000:qpmax=69:weightp=1:merange=24:chroma-qp-offset=-1:psy-rd=1.0:psy-rdoq=0.15:min-keyint=23"
    )

    video_map=(-map 0:v:0)

    logtofile "Paramètres vidéo HEVC configurés."
}

# -------------------------------------------------------------------
# Copier la vidéo sans réencodage
# -------------------------------------------------------------------
Copy_video()
{
    logtofile "Fonction Copy_video appelée."

    video_cmd=(-c:v copy)
    video_map=(-map 0:v:0)

    logtofile "Vidéo configurée en copie directe."
}

# -------------------------------------------------------------------
# Fonction principale d'encodage
# -------------------------------------------------------------------
execute_ffmpeg()
{
    logtofile "Fonction execute_ffmpeg appelée."

    # Initialiser les tableaux avant la configuration
    video_map=()
    video_cmd=()
    audio_map=()
    audio_cmd=()
    subtitle_map=()
    subtitle_cmd=()

    # Exécuter les fonctions de configuration sélectionnées
    if ! "$codec_video_function"; then
        logtofile "ERREUR : configuration vidéo impossible."
        return 1
    fi

    if ! "$codec_audio_function"; then
        logtofile "ERREUR : configuration audio impossible."
        return 1
    fi

    if ! "$codec_subtitle_function"; then
        logtofile "ERREUR : configuration des sous-titres impossible."
        return 1
    fi

    # Correction de la première erreur.
    # Construction de la commande avec un tableau Bash, sans eval.
    local -a args=(
        -threads 4
        -hide_banner
        -loglevel verbose
        -i "$INPUT_FILE"
    )

    args+=("${video_map[@]}")
    args+=("${audio_map[@]}")
    args+=("${subtitle_map[@]}")

    args+=("${video_cmd[@]}")
    args+=("${audio_cmd[@]}")
    args+=("${subtitle_cmd[@]}")

    # Sortie MKV : ne pas utiliser -movflags +faststart
    args+=("$OUTPUT_FILE")

    # Journaliser les arguments sans les réinterpréter
    logtofile "Arguments FFmpeg préparés :"

    local arg
    for arg in "$ffmpeg" "${args[@]}"; do
        printf -v arg '%q' "$arg"
        logtofile "  $arg"
    done

    local start_time
    local end_time
    local start_date
    local end_date
    local duration
    local hours
    local minutes
    local seconds
    local exit_code

    start_time=$(date +%s)
    start_date=$(date)

    logtofile "Début de l'encodage à $start_date..."

    # Exécution directe : chaque élément du tableau est un argument.
    "$ffmpeg" "${args[@]}"
    exit_code=$?

    end_time=$(date +%s)
    end_date=$(date)

    duration=$((end_time - start_time))
    hours=$((duration / 3600))
    minutes=$(((duration % 3600) / 60))
    seconds=$((duration % 60))

    logtofile "Encodage terminé à $end_date."
    logtofile "Temps d'exécution : $hours h, $minutes min, $seconds s."

    if [ "$exit_code" -eq 0 ]; then
        logtofile "FFmpeg s'est exécuté avec succès."
    else
        logtofile "ERREUR FFmpeg : code de sortie $exit_code."
    fi

    return "$exit_code"
}

# Laisser le script retourner le résultat de FFmpeg
execute_ffmpeg
exit $?