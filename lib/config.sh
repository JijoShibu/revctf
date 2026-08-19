#!/usr/bin/env bash
# lib/config.sh — ~/.revctf/config loading, key allowlist, and value coercion.
#
# Implemented in: M4 (extracted from the entry script).
# Sourced by the revctf entry script; never executed directly.
# Per v5 §4.1 this file must not enable `set -e`; a bad config line warns and falls back
# to the default rather than ending the run.
#
# WHY THIS FILE EXISTS SEPARATELY
# The loader is the single place an untrusted external value enters the option table, and
# QA-1 (critical) was exactly that: `full_hexdump = on` reached `[[ $x -eq 1 ]]`, which is
# arithmetic context, where `set -u` treats a non-numeric word as a variable name and
# EXITS THE SHELL — from inside a stage, where stage_run's error boundary cannot catch it.
# The isolate-and-continue guarantee of v5 §4.1 was silently void. Keeping coercion in one
# auditable file makes that class of defect visible rather than scattered.

# --------------------------------------------------------------------------------------
# Key registry
# --------------------------------------------------------------------------------------
# Every key a config file may set. An unknown key is reported and ignored, never silently
# applied (v6 §9) — a typo'd `flagformat` that did nothing while the user believed it was
# in force is worse than a warning.
CONFIG_ALLOWED="output_dir timeout flag_scan flag_format full_hexdump skip_ltrace \
skip_strace skip_ghidra no_unwrap unwrap_depth light_decompile force_full_decompile \
ghidra_script jobs_light jobs_ghidra maxmem_ghidra auto_swap sandbox tui strict \
stages_disabled summary_only"

# Keys consumed in arithmetic context. These MUST be coerced to 0/1 before they can reach
# `[[ $x -eq 1 ]]`. See QA-1 above.
CONFIG_BOOL_KEYS="flag_scan full_hexdump skip_ltrace skip_strace skip_ghidra no_unwrap \
light_decompile force_full_decompile auto_swap sandbox tui strict summary_only"

# Keys that must be whole numbers.
CONFIG_INT_KEYS="timeout unwrap_depth jobs_light jobs_ghidra"

# Keys holding a filesystem path, where a leading `~` needs expanding.
CONFIG_PATH_KEYS="output_dir ghidra_script"

# --------------------------------------------------------------------------------------
# config_load — read CONFIG_PATH into OPT, honouring CLI precedence.
# --------------------------------------------------------------------------------------
# Precedence (v6 §9): built-in defaults -> config file -> CLI flags. CLI_SET records which
# keys came from the command line, so a config value can never override an explicit flag.
config_load() {
    [[ -r $CONFIG_PATH ]] || {
        # An explicitly-requested config that does not exist is an error; the default one
        # simply being absent is not.
        [[ -n ${CLI_SET[config_path]:-} ]] && die "config file not readable: $CONFIG_PATH"
        return 0
    }

    local lineno=0 line key value
    while IFS= read -r line || [[ -n $line ]]; do
        lineno=$((lineno + 1))
        line="${line%%#*}"                       # strip comments
        line="${line#"${line%%[![:space:]]*}"}"  # ltrim
        line="${line%"${line##*[![:space:]]}"}"  # rtrim
        [[ -z $line ]] && continue

        if [[ $line != *=* ]]; then
            warn "$CONFIG_PATH:$lineno: ignoring malformed line (expected key=value)"
            continue
        fi

        key="${line%%=*}"; value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"

        if [[ " $CONFIG_ALLOWED " != *" $key "* ]]; then
            warn "$CONFIG_PATH:$lineno: ignoring unknown key '$key'"
            continue
        fi

        [[ -n ${CLI_SET[$key]:-} ]] && continue

        config_coerce "$key" "$value" "$CONFIG_PATH:$lineno" || continue
        # shellcheck disable=SC2034  # OPT is declared in the entry script and read everywhere
        OPT["$key"]="$CONFIG_VALUE"
    done < "$CONFIG_PATH"
    return 0
}

# config_coerce <key> <value> <where> — validate and normalise, result in CONFIG_VALUE.
#
# Returns non-zero when the value is unusable, having already warned; the caller then
# leaves the default in place. It never dies: a single bad line in a config file is not
# worth refusing to analyse a binary over.
declare -g CONFIG_VALUE=""
config_coerce() {
    local key="$1" value="$2" where="$3"
    CONFIG_VALUE=""

    if [[ " $CONFIG_BOOL_KEYS " == *" $key "* ]]; then
        case "${value,,}" in
            1|yes|true|on|enabled)   CONFIG_VALUE=1 ;;
            0|no|false|off|disabled) CONFIG_VALUE=0 ;;
            *)  warn "$where: '$key' expects a yes/no value (got '$value'); using the default"
                return 1 ;;
        esac
        return 0
    fi

    if [[ " $CONFIG_INT_KEYS " == *" $key "* ]]; then
        if ! is_uint "$value"; then
            warn "$where: '$key' expects a whole number (got '$value'); using the default"
            return 1
        fi
        CONFIG_VALUE="$value"
        return 0
    fi

    if [[ " $CONFIG_PATH_KEYS " == *" $key "* ]]; then
        # The config file is read, not sourced, so this is the only place `~` gets
        # expanded. README documents `output_dir = ~/ctf/reports`, which would otherwise
        # create a directory actually named "~". Compared character-wise to keep a
        # literal tilde out of a path context.
        if [[ ${value:0:1} == '~' ]] && [[ ${#value} -eq 1 || ${value:1:1} == '/' ]]; then
            value="$HOME${value:1}"
        fi
    fi

    CONFIG_VALUE="$value"
    return 0
}
