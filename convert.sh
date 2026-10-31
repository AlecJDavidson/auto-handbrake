#!/usr/bin/env bash

# =============================================================================
# auto-handbrake - Multi-GPU MKV to MP4 Transcoder
#
# Uses ffmpeg with VAAPI hardware acceleration to transcode MKV files to MP4
# using AMD/NVIDIA/Intel GPUs. Supports concurrent multi-GPU processing.
#
# Configuration via environment variables:
#   ENCODER         Video encoder (default: h264_vaapi)
#                   Options: h264_vaapi, hevc_vaapi, av1_vaapi, x264 (software)
#   VIDEO_QUALITY   Quality scale, lower = better (default: 22)
#   AUDIO_BITRATE   Bitrate for re-encoded audio (default: 192k)
#   GPU_COUNT       Number of GPUs to use (default: auto-detect)
#   GPU_DEVICES     Comma-separated render device paths (default: auto-detect)
#                   Example: /dev/dri/renderD128,/dev/dri/renderD129
# =============================================================================

set -uo pipefail

# =============================================================================
# Configuration
# =============================================================================

: "${ENCODER:=h264_vaapi}"
: "${VIDEO_QUALITY:=22}"
: "${AUDIO_BITRATE:=192k}"
: "${GPU_COUNT:=0}"       # 0 = auto-detect
: "${GPU_DEVICES:=}"      # empty = auto-detect

declare -A MEDIA_OPTIONS=(
    [1]="/mnt/media/anime"
    [2]="/mnt/media/tvshows"
    [3]="/mnt/media/movies"
)

EXCLUSION_PATHS=(
    "/mnt/media/downloads"
    "/mnt/media/downloads/incomplete"
    "/mnt/media/downloads/complete"
    "/mnt/media/downloads/deleted"
    "/mnt/media/music"
)

LOG_DIR="./logs"

# Conversion fail-log (ban list): a file that fails conversion this many times
# is recorded in BANNED_LOG and then skipped on every subsequent scan until the
# user removes its entry.
: "${CONVERSION_FAILURE_THRESHOLD:=3}"
: "${BANNED_LOG:="$LOG_DIR/banned.log"}"

# Colors for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BOLD='\033[1m'

# =============================================================================
# Utility Functions
# =============================================================================

log_info()  { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $(date '+%F %T') $*" >&2; }
log_ok()    { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $(date '+%F %T') $*" >&2; }
log_warn()  { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $(date '+%F %T') $*" >&2; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $(date '+%F %T') $*" >&2; }

# =============================================================================
# GPU Detection
# =============================================================================

detect_render_devices() {
    # Detect available GPU render nodes and return them as a sorted list.
    # In auto-detect mode, filters out integrated GPUs by checking VRAM size.
    local -a devices=()

    # If user specified devices, use those (no filtering)
    if [[ -n "$GPU_DEVICES" ]]; then
        IFS=',' read -ra devices <<< "$GPU_DEVICES"
        for dev in "${devices[@]}"; do
            if [[ ! -c "$dev" ]]; then
                log_error "Specified GPU device not found: $dev"
                return 1
            fi
        done
        printf '%s\n' "${devices[@]}"
        return 0
    fi

    # Auto-detect: find all render nodes in /dev/dri/
    local -a all_devices=()
    for dev in /dev/dri/renderD*; do
        [[ -c "$dev" ]] || continue
        all_devices+=("$dev")
    done

    if [[ ${#all_devices[@]} -eq 0 ]]; then
        log_error "No GPU render devices found in /dev/dri/"
        return 1
    fi

    # Filter: keep only discrete GPUs (VRAM > 1 GiB)
    # Integrated GPUs share system RAM and report 0 or small VRAM;
    # discrete GPUs have dedicated VRAM (typically 4+ GiB).
    local -a discrete_devices=()
    local vram_threshold=$((1 * 1024 * 1024 * 1024))  # 1 GiB in bytes

    for dev in "${all_devices[@]}"; do
        local minor="${dev##*/renderD}"
        local vram_path="/sys/class/drm/card$((minor - 128))/device/mem_info_vram_total"
        local vram=0

        if [[ -f "$vram_path" ]]; then
            vram=$(cat "$vram_path" 2>/dev/null || echo 0)
            # Convert to a clean numeric value (strip any whitespace/newlines)
            vram=$((vram + 0))
        fi

        if [[ "$vram" -gt "$vram_threshold" ]]; then
            discrete_devices+=("$dev")
        else
            log_info "Skipping integrated GPU (VRAM=$(numfmt --to=iec-i "$vram" 2>/dev/null || echo "$vram bytes")): $dev"
        fi
    done

    # Fallback: if no discrete GPUs found, use all available
    if [[ ${#discrete_devices[@]} -eq 0 ]]; then
        log_warn "No discrete GPUs detected. Falling back to all available GPUs."
        printf '%s\n' "${all_devices[@]}"
        return 0
    fi

    printf '%s\n' "${discrete_devices[@]}"
    return 0
}

detect_gpu_count() {
    # Return the number of available GPUs to use.
    if [[ "$GPU_COUNT" -gt 0 ]]; then
        echo "$GPU_COUNT"
        return 0
    fi

    local count
    count=$(detect_render_devices 2>/dev/null | wc -l)
    if [[ "$count" -eq 0 ]]; then
        echo 0
        return 1
    fi
    echo "$count"
}

find_gpu_for_slot() {
    # Find the render device for a given slot index (0-based).
    local slot=$1
    local -a devices=()
    while IFS= read -r dev; do
        devices+=("$dev")
    done < <(detect_render_devices 2>/dev/null)
    if [[ $slot -lt ${#devices[@]} ]]; then
        echo "${devices[$slot]}"
    else
        echo ""
    fi
}

# =============================================================================
# Media Stream Analysis
# =============================================================================

analyze_audio_streams() {
    # Analyze audio streams and decide copy vs re-encode.
    # Returns lines of 'copy:<stream_idx>' or 'encode:<stream_idx>:<bitrate>'
    local input_file=$1

    # Get audio stream info: index and codec_name
    local audio_info
    audio_info=$(ffprobe -v quiet -select_streams a \
        -show_entries stream=index,codec_name \
        -of csv=p=0 "$input_file" 2>/dev/null)

    if [[ -z "$audio_info" ]]; then
        echo "no_audio"
        return
    fi

    local output_idx=0
    while IFS=',' read -r stream_idx codec_name; do
        # Normalize whitespace
        codec_name="${codec_name// /}"
        case "$codec_name" in
            aac|ac3|mp3|eac3|mp4a)
                echo "copy:$output_idx"
                ;;
            flac|alac|opus|vorbis|pcm*)
                # Re-encode lossless/uncommon audio to AAC for MP4 compatibility
                echo "encode:$output_idx:$AUDIO_BITRATE"
                ;;
            dts|dca|truehd|mlp|wmapro|wmav2)
                # Re-encode high-bitrate/uncommon audio to AAC
                echo "encode:$output_idx:$AUDIO_BITRATE"
                ;;
            *)
                # Fallback: re-encode any unknown codec
                echo "encode:$output_idx:$AUDIO_BITRATE"
                ;;
        esac
        ((output_idx++))
    done <<< "$audio_info"
}

analyze_subtitle_streams() {
    # Analyze subtitle streams and decide which can be kept.
    # Returns lines of 'keep:<stream_idx>:<codec>' or 'skip:<stream_idx>:<codec>'
    local input_file=$1

    # Get subtitle stream info
    local sub_info
    sub_info=$(ffprobe -v quiet -select_streams s \
        -show_entries stream=index,codec_name \
        -of csv=p=0 "$input_file" 2>/dev/null)

    if [[ -z "$sub_info" ]]; then
        echo "no_subs"
        return
    fi

    while IFS=',' read -r stream_idx codec_name; do
        codec_name="${codec_name// /}"
        case "$codec_name" in
            subrip|subtext|text|mov_text)
                echo "keep:$stream_idx:$codec_name"
                ;;
            ass|ssa)
                echo "keep:$stream_idx:$codec_name"
                ;;
            hdmv_pgs|dvd_subtitle|dvd_sub|dvb_subtitle|vobsub)
                echo "skip:$stream_idx:$codec_name"
                ;;
            *)
                echo "skip:$stream_idx:$codec_name"
                ;;
        esac
    done <<< "$sub_info"
}

# =============================================================================
# Single File Conversion
# =============================================================================

convert_file() {
    # Convert a single MKV file to MP4 using GPU-accelerated encoding.
    # Arguments:
    #   $1: input_file - Source MKV file
    #   $2: output_file - Destination MP4 file
    #   $3: log_file - Path to log file
    #   $4: render_device - GPU render device (e.g., /dev/dri/renderD128)
    #   $5: gpu_slot - Slot number for display
    # Returns: 0 on success, non-zero on failure
    local input_file=$1
    local output_file=$2
    local log_file=$3
    local render_device=$4
    local gpu_slot=$5

    # Build ffmpeg arguments
    local -a ffmpeg_args=()
    local using_hardware=false

    if [[ "$ENCODER" != x264 ]]; then
        using_hardware=true
        # Hardware-accelerated path: software decode + VAAPI encode
        # Using -vaapi_device instead of -hwaccel vaapi ensures maximum
        # compatibility across source formats (8-bit, 10-bit, H.264, HEVC, AV1).
        # The hwupload filter uploads the software-decoded frame to the GPU.
        ffmpeg_args+=(
            -vaapi_device "$render_device"
        )
    fi

    ffmpeg_args+=(-i "$input_file")

    # For hardware encoding, add pixel format conversion and GPU upload
    if [[ "$using_hardware" == true ]]; then
        # Convert to nv12 (8-bit) for maximum VAAPI encoder compatibility.
        # RX 6800 XT h264_vaapi supports 8-bit only; 10-bit sources need
        # a format conversion before hwupload.
        ffmpeg_args+=(
            -vf "format=nv12,hwupload"
        )
    fi

    # --- Audio handling ---
    local audio_decisions
    audio_decisions=$(analyze_audio_streams "$input_file")

    if [[ "$audio_decisions" == "no_audio" ]]; then
        ffmpeg_args+=(-an)
    else
        local has_encode=false
        while IFS=':' read -r action idx bitrate; do
            case "$action" in
                copy)
                    ffmpeg_args+=("-c:a:$idx" copy)
                    ;;
                encode)
                    ffmpeg_args+=("-c:a:$idx" aac -b:a:$idx "$bitrate")
                    has_encode=true
                    ;;
            esac
        done <<< "$audio_decisions"
    fi

    # --- Subtitle handling ---
    # Strategy: explicitly map only text-based subtitle streams that can be
    # converted to mov_text (MP4 compatible). Skip bitmap subtitles entirely
    # rather than trying to exclude them with -map "-0:N" (which fails when
    # ffprobe finds streams that ffmpeg can't fully parse).
    local sub_decisions
    sub_decisions=$(analyze_subtitle_streams "$input_file")
    local -a keep_sub_indices=()

    if [[ "$sub_decisions" != "no_subs" ]]; then
        while IFS=':' read -r action idx codec; do
            case "$action" in
                keep) keep_sub_indices+=("$idx") ;;
                skip) ;;  # Silently skip bitmap/PGS subtitles (not MP4-compatible)
            esac
        done <<< "$sub_decisions"
    fi

    # Map streams explicitly to avoid fragile negative map exclusions
    ffmpeg_args+=(-map 0:v -map 0:a)  # All video and audio streams

    if [[ ${#keep_sub_indices[@]} -gt 0 ]]; then
        for idx in "${keep_sub_indices[@]}"; do
            ffmpeg_args+=(-map "0:$idx")
        done
        ffmpeg_args+=(-c:s mov_text)
    fi

    # --- Video encoder ---
    if [[ "$ENCODER" == x264 ]]; then
        # Software fallback
        ffmpeg_args+=(-c:v libx264 -crf "$VIDEO_QUALITY" -preset fast)
    else
        # Hardware VAAPI encoder
        ffmpeg_args+=(
            -c:v "$ENCODER"
            -global_quality "$VIDEO_QUALITY"
        )
        # Add encoder-specific presets
        case "$ENCODER" in
            h264_vaapi)
                ffmpeg_args+=(-compression_level 1)
                ;;
            hevc_vaapi|av1_vaapi)
                ffmpeg_args+=(-compression_level 1)
                ;;
        esac
    fi

    # --- Container options ---
    ffmpeg_args+=(
        -movflags +faststart
        -y
        "$output_file"
    )

    # --- Execute ---
    {
        echo "========================================================="
        echo " Conversion started: $(date '+%F %T')"
        echo " Source: $input_file"
        echo " Output: $output_file"
        echo " GPU slot: $gpu_slot ($render_device)"
        echo " Encoder: $ENCODER"
        echo " Quality: $VIDEO_QUALITY"
        echo "========================================================="
        echo ""
        echo "ffmpeg command:"
        echo "  ffmpeg ${ffmpeg_args[*]}"
        echo ""
    } >> "$log_file"

    # Run ffmpeg
    ffmpeg "${ffmpeg_args[@]}" >> "$log_file" 2>&1
    local exit_code=$?

    {
        echo ""
        echo "========================================================="
        echo " Conversion finished: $(date '+%F %T')"
        echo " Exit code: $exit_code"
        echo "========================================================="
    } >> "$log_file"

    return $exit_code
}

# =============================================================================
# Conversion Fail-Log (Ban List)
#
# A file that fails conversion CONVERSION_FAILURE_THRESHOLD times is recorded in
# BANNED_LOG and then skipped on every subsequent scan until the user removes its
# entry. The log is one entry per line in the format:
#
#     <failure_count><TAB><file_path>
#
# Comment lines (starting with '#') and blank lines are preserved verbatim so the
# file stays human-readable and easy to edit.
# =============================================================================

ensure_banned_log() {
    # Create the banned log with its header comment if it does not yet exist.
    if [[ ! -f "$BANNED_LOG" ]]; then
        mkdir -p "$(dirname "$BANNED_LOG")"
        cat > "$BANNED_LOG" <<'EOF'
# auto-handbrake - permanent conversion failure log
# Format per line: <failure_count><TAB><file_path>
# A file is skipped once its failure count reaches the threshold (default 3).
# Delete the line (or edit the count) to allow the file to be converted again.
EOF
    fi
}

record_failure() {
    # Increment the failure counter for a file in the banned log. If the file
    # reaches the failure threshold it is logged as permanently banned.
    # $1: file path
    local file=$1

    ensure_banned_log

    local tmp; tmp=$(mktemp "${BANNED_LOG}.XXXXXX")
    local count=0 found=0 line c path
    while IFS= read -r line; do
        case "$line" in
            '#'*|'')
                # Preserve header/comment and blank lines verbatim.
                printf '%s\n' "$line" >> "$tmp"
                ;;
            *)
                c=${line%%$'\t'*}
                path=${line#*$'\t'}
                if [[ "$path" == "$file" ]]; then
                    # Sanitize to a clean integer (ignore stray characters).
                    [[ "$c" =~ ^[0-9]+$ ]] || c=0
                    count=$((c + 1))
                    found=1
                    printf '%s\t%s\n' "$count" "$path" >> "$tmp"
                else
                    printf '%s\t%s\n' "$c" "$path" >> "$tmp"
                fi
                ;;
        esac
    done < "$BANNED_LOG"

    if [[ $found -eq 0 ]]; then
        count=1
        printf '%s\t%s\n' "$count" "$file" >> "$tmp"
    fi

    mv -f "$tmp" "$BANNED_LOG"
    chmod 0644 "$BANNED_LOG" 2>/dev/null || true

    if [[ $count -ge "$CONVERSION_FAILURE_THRESHOLD" ]]; then
        log_error "BANNED: '$file' failed $count time(s) (threshold=$CONVERSION_FAILURE_THRESHOLD); skipping forever. Remove its entry from '$BANNED_LOG' to re-enable."
    fi
}

is_banned() {
    # Return 0 if the given file has reached the failure threshold, i.e. it must
    # be skipped on this and all subsequent passes.
    local file=$1
    local line c path
    while IFS= read -r line; do
        case "$line" in
            '#'*|'') continue ;;
        esac
        c=${line%%$'\t'*}
        path=${line#*$'\t'}
        if [[ "$path" == "$file" ]]; then
            [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge "$CONVERSION_FAILURE_THRESHOLD" ]] && return 0
        fi
    done < "$BANNED_LOG" 2>/dev/null
    return 1
}

list_banned() {
    # Print a human-readable list of all currently-banned files.
    if [[ ! -f "$BANNED_LOG" ]]; then
        echo "No banned files yet (log '$BANNED_LOG' does not exist)."
        return 0
    fi

    echo "Permanently banned files in '$BANNED_LOG' (failures >= $CONVERSION_FAILURE_THRESHOLD):"
    echo "========================================================="

    local line c path banned_count=0
    while IFS= read -r line; do
        case "$line" in
            '#'*|'') continue ;;
        esac
        c=${line%%$'\t'*}
        path=${line#*$'\t'}
        if [[ "$c" =~ ^[0-9]+$ && "$c" -ge "$CONVERSION_FAILURE_THRESHOLD" ]]; then
            printf '  [%s failures]  %s\n' "$c" "$path"
            ((banned_count++))
        fi
    done < "$BANNED_LOG"

    [[ $banned_count -eq 0 ]] && echo "  (none banned)"

    echo "========================================================="
    echo "Remove a line from '$BANNED_LOG' to re-enable that file."
}

# =============================================================================
# Concurrent Multi-GPU Processing
# =============================================================================

run_concurrent_conversion() {
    # Process MKV files concurrently across available GPUs.
    local -a files=("$@")
    local total=${#files[@]}
    local gpu_count
    gpu_count=$(detect_gpu_count)

    if [[ "$gpu_count" -eq 0 ]]; then
        log_warn "No GPU render devices detected."
        if command -v ffmpeg &>/dev/null && \
           ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "libx264"; then
            log_info "Falling back to software encoding (libx264)."
            ENCODER=x264
            gpu_count=1  # Use a single slot for software encoding
        else
            log_error "No GPU available and no software encoder found. Aborting."
            exit 1
        fi
    else
        log_info "Detected $gpu_count GPU(s):"
        for ((i = 0; i < gpu_count; i++)); do
            local dev
            dev=$(find_gpu_for_slot "$i")
            log_info "  GPU $i: $dev"
        done
    fi

    log_info "Starting conversion of $total file(s) across $gpu_count concurrent slot(s)"
    log_info "Encoder: $ENCODER, Quality: $VIDEO_QUALITY"
    echo ""

    # --- Setup ---
    mkdir -p "$LOG_DIR"

    # Initialize slot tracking
    declare -a slot_pids=()       # PID per slot (0 = free)
    declare -a slot_devices=()    # Render device per slot
    declare -a slot_files=()      # Source file per slot
    declare -a slot_outputs=()    # Output file per slot

    for ((i = 0; i < gpu_count; i++)); do
        slot_devices+=("$(find_gpu_for_slot "$i")")
        slot_pids+=(0)
        slot_files+=("")
        slot_outputs+=("")
    done

    local next_file_index=0
    local successes=0
    local failures=0
    local active_jobs=0

    # --- Main processing loop ---
    while [[ $next_file_index -lt $total ]] || [[ $active_jobs -gt 0 ]]; do

        # 1. Reap finished processes
        for ((i = 0; i < ${#slot_pids[@]}; i++)); do
            local pid=${slot_pids[$i]}

            if [[ "$pid" -ne 0 ]] && ! kill -0 "$pid" 2>/dev/null; then
                # Process has finished, collect its result
                wait "$pid" 2>/dev/null
                local exit_code=$?
                local src="${slot_files[$i]}"
                local out="${slot_outputs[$i]}"

                if [[ $exit_code -eq 0 ]]; then
                    log_ok "Converted: $out"
                    rm -f "$src"
                    log_info "Deleted source: $src"
                    ((successes++))
                else
                    log_error "Failed: $src (exit code $exit_code)"
                    record_failure "$src"
                    ((failures++))
                fi

                # Free the slot
                slot_pids[$i]=0
                slot_files[$i]=""
                slot_outputs[$i]=""
                ((active_jobs--))
            fi
        done

        # 2. Start new jobs in free slots
        while [[ $next_file_index -lt $total ]]; do
            # Find a free slot
            local free_slot=-1
            for ((i = 0; i < ${#slot_pids[@]}; i++)); do
                if [[ "${slot_pids[$i]}" -eq 0 ]]; then
                    free_slot=$i
                    break
                fi
            done

            # No free slots available
            [[ $free_slot -eq -1 ]] && break

            local file="${files[$next_file_index]}"
            local output="${file%.mkv}.mp4"
            local log_file="$LOG_DIR/$(basename "${file%.mkv}").log"
            local device="${slot_devices[$free_slot]}"

            # If no device assigned (software or unknown), use generic device
            if [[ -z "$device" ]]; then
                device="/dev/dri/renderD$((128 + free_slot))"
            fi

            log_info "Starting: $(basename "$file") on GPU $free_slot"

            # Launch conversion in background
            convert_file "$file" "$output" "$log_file" "$device" "$free_slot" &
            local new_pid=$!

            slot_pids[$free_slot]=$new_pid
            slot_files[$free_slot]=$file
            slot_outputs[$free_slot]=$output
            ((active_jobs++))
            ((next_file_index++))
        done

        # 3. Brief pause to avoid busy-waiting
        if [[ $active_jobs -gt 0 ]]; then
            sleep 3
        fi
    done

    # --- Summary ---
    echo ""
    echo "========================================================="
    echo -e "${COLOR_BOLD}Conversion Complete${COLOR_RESET}"
    echo "  Total files:   $total"
    echo -e "  ${COLOR_GREEN}Successful:${COLOR_RESET}   $successes"
    if [[ $failures -gt 0 ]]; then
        echo -e "  ${COLOR_RED}Failed:${COLOR_RESET}       $failures"
    fi
    echo "========================================================="
}

# =============================================================================
# Directory Selection
# =============================================================================

select_base_directory() {
    # Prompt user to select which media directory to process.
    echo "========================================================="
    echo -e "${COLOR_BOLD}MKV to MP4 Converter - Multi-GPU Edition${COLOR_RESET}"
    echo "========================================================="
    echo "Please select the primary directory you want to process:"

    for key in 1 2 3; do
        local dir="${MEDIA_OPTIONS[$key]}"
        if [[ -d "$dir" ]]; then
            echo "  [$key] $dir"
        else
            echo "  [$key] (Not Found) $dir"
        fi
    done

    local selection
    read -r -p "Enter the number corresponding to the desired base directory: " selection

    if [[ -z "${MEDIA_OPTIONS[$selection]}" ]]; then
        echo ""
        echo -e "${COLOR_RED}Invalid selection. Exiting script.${COLOR_RESET}"
        exit 1
    fi

    BASE_DIR="${MEDIA_OPTIONS[$selection]}"

    if [[ ! -d "$BASE_DIR" ]]; then
        echo ""
        echo -e "${COLOR_RED}Error: The specified base directory '$BASE_DIR' does not exist. Exiting script.${COLOR_RESET}"
        exit 1
    fi

    echo "========================================================="
    echo -e "${COLOR_GREEN}Selected Base Directory:${COLOR_RESET} $BASE_DIR"
    echo -e "${COLOR_CYAN}Exclusions:${COLOR_RESET} ${EXCLUSION_PATHS[*]}"
    echo "========================================================="
}

# =============================================================================
# Main Execution
# =============================================================================

list_gpus() {
    # Display all detected GPUs with their type (discrete vs integrated).
    echo -e "${COLOR_BOLD}Available GPU Devices${COLOR_RESET}"
    echo "========================================================="

    local -a all_devices=()
    for dev in /dev/dri/renderD*; do
        [[ -c "$dev" ]] || continue
        all_devices+=("$dev")
    done

    if [[ ${#all_devices[@]} -eq 0 ]]; then
        echo -e "${COLOR_RED}No GPU render devices found.${COLOR_RESET}"
        exit 0
    fi

    local vram_threshold=$((1 * 1024 * 1024 * 1024))

    for dev in "${all_devices[@]}"; do
        local minor="${dev##*/renderD}"
        local card_idx=$((minor - 128))
        local vram_path="/sys/class/drm/card${card_idx}/device/mem_info_vram_total"
        local vram=0
        local gpu_type="unknown"

        if [[ -f "$vram_path" ]]; then
            vram=$(cat "$vram_path" 2>/dev/null || echo 0)
            vram=$((vram + 0))
            if [[ "$vram" -gt "$vram_threshold" ]]; then
                gpu_type="${COLOR_GREEN}DISCRETE${COLOR_RESET}"
            else
                gpu_type="${COLOR_YELLOW}INTEGRATED${COLOR_RESET}"
            fi
        fi

        local vram_hr
        if command -v numfmt &>/dev/null; then
            vram_hr=$(numfmt --to=iec-i "$vram" 2>/dev/null || echo "${vram}B")
        else
            vram_hr="${vram} bytes"
        fi

        # Try to get GPU model name from lspci
        local pci_addr
        if [[ -L "/sys/class/drm/renderD${minor}/device" ]]; then
            pci_addr=$(readlink -f "/sys/class/drm/renderD${minor}/device" 2>/dev/null)
            pci_addr=$(basename "$pci_addr" 2>/dev/null || echo "unknown")
        else
            pci_addr="unknown"
        fi

        local model=""
        if command -v lspci &>/dev/null && [[ "$pci_addr" != "unknown" ]]; then
            model=$(lspci -s "${pci_addr#0000:}" 2>/dev/null | sed 's/.*: //' || echo "")
        fi

        echo -e "  $dev"
        echo -e "    Type:   $gpu_type"
        echo -e "    VRAM:   $vram_hr"
        echo -e "    PCI:    ${pci_addr#0000:}"
        if [[ -n "$model" ]]; then
            echo -e "    Model:  $model"
        fi
        echo ""
    done

    echo "========================================================="
    echo -e "Discrete GPUs will be used for transcoding. ${COLOR_YELLOW}Integrated GPUs are skipped automatically.${COLOR_RESET}"
    exit 0
}

main() {
    # Check prerequisites
    if ! command -v ffmpeg &>/dev/null; then
        log_error "ffmpeg is not installed. Please install ffmpeg (e.g., 'sudo pacman -S ffmpeg')."
        exit 1
    fi

    if ! command -v ffprobe &>/dev/null; then
        log_error "ffprobe is not installed. Please install ffmpeg (ffprobe is included)."
        exit 1
    fi

    # Check encoder availability
    # Note: ffmpeg may output encoder list to stderr on some builds
    if [[ "$ENCODER" != x264 ]]; then
        local ffmpeg_encoders
        ffmpeg_encoders=$(ffmpeg -hide_banner -encoders 2>&1)
        if ! echo "$ffmpeg_encoders" | grep -qiF "${ENCODER}"; then
            log_warn "Encoder '$ENCODER' not found in ffmpeg. Available VAAPI encoders:"
            echo "$ffmpeg_encoders" | grep -i vaapi | awk '{print "  " $2}'
            log_warn "Falling back to software encoder (libx264)."
            ENCODER=x264
        fi
    fi

    # Show configuration
    echo ""
    echo -e "${COLOR_BOLD}Configuration:${COLOR_RESET}"
    echo "  Encoder:       $ENCODER"
    echo "  Quality:       $VIDEO_QUALITY"
    echo "  Audio bitrate: $AUDIO_BITRATE"
    echo "  GPU devices:   ${GPU_DEVICES:-auto-detect (discrete only)}"
    echo "  GPU count:     ${GPU_COUNT:-auto}"
    echo ""

    select_base_directory

    mkdir -p "$LOG_DIR"
    ensure_banned_log
    log_info "Starting MKV conversion loop in directory: $BASE_DIR..."
    log_info "Fail-log: '$BANNED_LOG' (a file is banned after $CONVERSION_FAILURE_THRESHOLD failures)"

    local total_converted=0
    local total_failed=0
    local pass_num=1

    local exclude_args=""
    for path in "${EXCLUSION_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            exclude_args+=" -path \"$path\" -prune -o "
        fi
    done

    while true; do
        echo ""
        log_info "Pass $pass_num: scanning for MKV files..."

        local -a files=()
        local banned_count=0
        while IFS= read -r -d '' file; do
            if is_banned "$file"; then
                log_warn "Skipping banned file (>= $CONVERSION_FAILURE_THRESHOLD failures): $(basename "$file")"
                ((banned_count++))
                continue
            fi
            files+=("$file")
        done < <(
            eval find "$BASE_DIR" \
                "$exclude_args" \
                -type f -iname "*.mkv" -print0 2>/dev/null
        )

        if [[ ${#files[@]} -eq 0 ]]; then
            if [[ "$banned_count" -gt 0 ]]; then
                log_info "All discovered file(s) are banned; nothing to do."
            else
                log_info "No MKV files found. Exiting."
            fi
            break
        fi

        log_info "Files found: ${#files[@]}"
        if [[ "$banned_count" -gt 0 ]]; then
            log_info "Skipped $banned_count banned file(s) - see '$BANNED_LOG'."
        fi

        # Process files concurrently across GPUs
        run_concurrent_conversion "${files[@]}"

        pass_num=$((pass_num + 1))
    done

    echo ""
    echo "========================================================="
    log_info "All passes complete."
    echo "========================================================="
}

if [[ "${1:-}" == "--list-gpus" ]]; then
    list_gpus
fi

if [[ "${1:-}" == "--banned" ]]; then
    ensure_banned_log
    list_banned
    exit 0
fi

main "$@"
