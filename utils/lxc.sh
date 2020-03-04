#!/usr/bin/env bash
# -*- coding: utf-8; mode: sh indent-tabs-mode: nil -*-
# SPDX-License-Identifier: AGPL-3.0-or-later

# shellcheck source=utils/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source_dot_config
source "${REPO_ROOT}/utils/lxc.env"

# ----------------------------------------------------------------------------
# config
# ----------------------------------------------------------------------------
#
# read also:
# - https://lxd.readthedocs.io/en/latest/

# name of https://images.linuxcontainers.org
LINUXCONTAINERS_ORG_NAME="${LINUXCONTAINERS_ORG_NAME:-images}"
HOST_PREFIX="${HOST_PREFIX:-searx}"

# where all folders from HOST are mounted
LXC_SHARE_FOLDER="/share"
LXC_REPO_ROOT="${LXC_SHARE_FOLDER}/$(basename "${REPO_ROOT}")"

TEST_IMAGES=(
    "$LINUXCONTAINERS_ORG_NAME:ubuntu/18.04"  "ubu1804"
    "$LINUXCONTAINERS_ORG_NAME:ubuntu/19.04"  "ubu1904"
    "$LINUXCONTAINERS_ORG_NAME:ubuntu/19.10"  "ubu1910"
    "$LINUXCONTAINERS_ORG_NAME:ubuntu/20.04"  "ubu2004"
    "$LINUXCONTAINERS_ORG_NAME:archlinux"     "archlinux"
    "$LINUXCONTAINERS_ORG_NAME:fedora/31"     "fedora31"
)

ubu1804_boilerplate="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y git curl wget
"
ubu1904_boilerplate="$ubu1804_boilerplate"
ubu1910_boilerplate="$ubu1904_boilerplate"
# shellcheck disable=SC2034
ubu2004_boilerplate="$ubu1910_boilerplate"

# shellcheck disable=SC2034
archlinux_boilerplate="
pacman -Syu --noconfirm
pacman -S --noconfirm git curl wget sudo
echo 'Set disable_coredump false' >> /etc/sudo.conf
"

# shellcheck disable=SC2034
fedora31_boilerplate="
dnf update -y
dnf install -y git curl wget hostname
echo 'Set disable_coredump false' >> /etc/sudo.conf
"

REMOTE_IMAGES=()
LOCAL_IMAGES=()

for ((i=0; i<${#TEST_IMAGES[@]}; i+=2)); do
    REMOTE_IMAGES=("${REMOTE_IMAGES[@]}" "${TEST_IMAGES[i]}")
    LOCAL_IMAGES=("${LOCAL_IMAGES[@]}" "${HOST_PREFIX}-${TEST_IMAGES[i+1]}")
done

HOST_USER="${SUDO_USER:-$USER}"
HOST_USER_ID=$(id -u "${HOST_USER}")
HOST_GROUP_ID=$(id -g "${HOST_USER}")

# ----------------------------------------------------------------------------
usage() {
# ----------------------------------------------------------------------------

    cat <<EOF

usage::

  $(basename "$0") build        [containers]
  $(basename "$0") install      [searx-suite]
  $(basename "$0") remove       [containers|subordinate]
  $(basename "$0") [start|stop] [containers|<container-name>]
  $(basename "$0") show         [info|config|searx-suite]
  $(basename "$0") cmd          ...

build / remove
  :containers:   build & launch (or remove) all LXC containers
add / remove
  :subordinate:  lxd permission to map ${HOST_USER}'s user/group id through
start/stop
  :containers:   start/stop of all 'containers' or only <container-name>
show
  :info:         show info of all containers
  :config:       show config of all containers
  :searx-suite:  show searx-suite services of all containers
cmd ...
  run commandline ... in all containers
install
  :searx-suite:  install searx suite, includes morty & filtron

all LXC containers:
  ${LOCAL_IMAGES[@]}

EOF
    [ -n "${1+x}" ] &&  err_msg "$1"
}

lxd_info() {

    cat <<EOF

LXD is needed, to install run::

  snap install lxd
  lxd init --auto

EOF
}

main() {

    local exit_val
    local _usage="unknown or missing $1 command $2"

    if [[ ! $1 == __* ]] && ! required_commands lxc; then
        lxd_info
        exit 42
    fi
    case $1 in
        --source-only)  ;;
        -h|--help) usage; exit 0;;

        build)
            sudo_or_exit
            case $2 in
                containers) build_instances ;;
                *) usage "$_usage"; exit 42;;
            esac
            ;;
        remove)
            sudo_or_exit
            case $2 in
                containers) remove_instances ;;
                subordinate) echo; del_subordinate_ids ;;
                *) usage "$_usage"; exit 42;;
            esac
            ;;
        add)
            sudo_or_exit
            case $2 in
                subordinate) echo; add_subordinate_ids ;;
                *) usage "$_usage"; exit 42;;
            esac
            ;;
        start|stop)
            sudo_or_exit
            case $2 in
                containers)  lxc_cmd "$1" ;;
                *)
                    info_msg "lxc $1 $2"
                    lxc "$1" "$2" | prefix_stdout "[${_BBlue}${i}${_creset}] "
                    ;;
            esac
            ;;
        show)
            sudo_or_exit
            case $2 in
                config) lxc_cmd config show;;
                info) lxc_cmd info;;
                searx-suite)
                    for i in "${LOCAL_IMAGES[@]}"; do
                        info_msg "[${_BBlue}${i}${_creset}] ${_BGreen}${LXC_REPO_ROOT}/utils/lxc.sh install $2${_creset}"
                        lxc exec -t "${i}" -- "${LXC_REPO_ROOT}/utils/lxc.sh" __show "$2"  | prefix_stdout "[${i}] "
                    done
                    ;;
                *) usage "$_usage"; exit 42;;
            esac
            ;;
        __show)
            case $2 in
                searx-suite) searx_suite_info ;;
            esac
            ;;
        cmd)
            sudo_or_exit
            shift
            for i in "${LOCAL_IMAGES[@]}"; do
                exit_val=
                info_msg "[${_BBlue}${i}${_creset}] ${_BGreen}${*}${_creset}"
                lxc exec "${i}" -- "$@"
                exit_val=$?
                if [[ $exit_val -ne 0 ]]; then
                    warn_msg "[${_BBlue}${i}${_creset}] exit code (${_BRed}${exit_val}${_creset}) from ${_BGreen}${*}${_creset}"
                else
                    info_msg "[${_BBlue}${i}${_creset}] exit code (${exit_val}) from ${_BGreen}${*}${_creset}"
                fi
                echo
            done
            ;;
        install)
            sudo_or_exit
            case $2 in
                searx-suite)
                    for i in "${LOCAL_IMAGES[@]}"; do
                        info_msg "[${_BBlue}${i}${_creset}] ${_BGreen}${LXC_REPO_ROOT}/utils/lxc.sh install $2${_creset}"
                        lxc exec -t "${i}" -- "${LXC_REPO_ROOT}/utils/lxc.sh" __install "$2"  | prefix_stdout "[${i}] "
                    done
                    ;;
                *) usage "$_usage"; exit 42;;
            esac
            ;;
        __install)
            case $2 in
                searx-suite) searx_suite_install ;;
            esac
            ;;
        doc)
            echo
            echo ".. generic utils/lxc.sh documentation"
            ;;

        *)
            usage "unknown or missing command $1"; exit 42;;
    esac
}

searx_suite_install() {
    (
        searx_suite_set_env
        export FORCE_TIMEOUT=0
        "${LXC_REPO_ROOT}/utils/searx.sh"   install all
        "${LXC_REPO_ROOT}/utils/morty.sh"   install all
        "${LXC_REPO_ROOT}/utils/filtron.sh" install all

        rst_title "searx-suite installation finished ($(hostname))" part
        searx_suite_info
        echo
    )
}

searx_suite_info() {
    (
        searx_suite_set_env
        rst_para "Services of the container $(hostname)"
        for ip in $(hostname -I); do
            echo
            if [[ $ip =~ .*:.* ]]; then
                :
                # IPv6: not yet implemented / tested
                # echo " searx (filtron) --> http://[$ip]:4004/"
                # echo " morty           --> http://[$ip]:3000/"
            else
                # IPv4:
                echo " searx (filtron) --> http://$ip:4004/"
                echo " morty           --> http://$ip:3000/"
            fi
        done
    )
}

build_instances() {
    rst_title "Build LXC instances"

    rst_title "copy images" section
    echo
    lxc_copy_images_localy
    # lxc image list local: && wait_key
    echo
    rst_title "build containers" section
    echo
    lxc_init_containers
    lxc_config_containers
    lxc_boilerplate_containers
    echo
    lxc list "$HOST_PREFIX"
}

remove_instances() {
    rst_title "Remove LXC instances"
    lxc list "$HOST_PREFIX"
    echo -en "\\nLXC containers(s)::\\n\\n  ${LOCAL_IMAGES[*]}\\n" | $FMT
    if ask_yn "Do you really want to delete all images"; then
        lxc_delete_containers
    fi
    echo
    lxc list "$HOST_PREFIX"
    # lxc image list local: && wait_key
}

# images
# ------

lxc_copy_images_localy() {
    for ((i=0; i<${#TEST_IMAGES[@]}; i+=2)); do
        if lxc image info "local:${TEST_IMAGES[i+1]}" &>/dev/null; then
            info_msg "image ${TEST_IMAGES[i]} already copied --> ${TEST_IMAGES[i+1]}"
        else
            info_msg "copy image locally ${TEST_IMAGES[i]} --> ${TEST_IMAGES[i+1]}"
            lxc image copy "${TEST_IMAGES[i]}" local: \
                --alias  "${TEST_IMAGES[i+1]}" | prefix_stdout
        fi
    done
}

lxc_delete_images_localy() {
    echo
    for i in "${LOCAL_IMAGES[@]}"; do
        info_msg "delete image 'local:$i'"
        lxc image delete "local:$i"
    done
    #lxc image list local:
}

# container
# ---------

lxc_cmd() {
    for i in "${LOCAL_IMAGES[@]}"; do
        info_msg "lxc $* $i"
        lxc "$@" "$i" | prefix_stdout "[${_BBlue}${i}${_creset}] "
    done
}

lxc_init_containers() {

    local image_name
    local container_name

    for ((i=0; i<${#TEST_IMAGES[@]}; i+=2)); do

        image_name="${TEST_IMAGES[i+1]}"
        container_name="${HOST_PREFIX}-${image_name}"

        if lxc info "${container_name}" &>/dev/null; then
            info_msg "container '${container_name}' already exists"
        else
            info_msg "create conatiner instance: ${container_name}"
            lxc init "local:${image_name}" "${container_name}"
        fi
    done
}

lxc_config_containers() {
    for i in "${LOCAL_IMAGES[@]}"; do
        info_msg "[${_BBlue}${i}${_creset}] configure container ..."

        info_msg "[${_BBlue}${i}${_creset}] map uid/gid from host to container"
        # https://lxd.readthedocs.io/en/latest/userns-idmap/#custom-idmaps
        echo -e -n "uid $HOST_USER_ID 1000\\ngid $HOST_GROUP_ID 1000"\
            | lxc config set "$i" raw.idmap -

        info_msg "[${_BBlue}${i}${_creset}] share ${REPO_ROOT} (repo_share) from HOST into container"
        # https://lxd.readthedocs.io/en/latest/instances/#type-disk
        lxc config device add "$i" repo_share disk \
            source="${REPO_ROOT}" \
            path="${LXC_REPO_ROOT}" &>/dev/null
        # lxc config show "$i" && wait_key
    done
}

lxc_boilerplate_containers() {

    local image_name
    local container_name
    local boilerplate_script

    for ((i=0; i<${#TEST_IMAGES[@]}; i+=2)); do

        image_name="${TEST_IMAGES[i+1]}"
        container_name="${HOST_PREFIX}-${image_name}"
        boilerplate_script="${image_name}_boilerplate"
        boilerplate_script="${!boilerplate_script}"

        info_msg "[${_BBlue}${container_name}${_creset}] install boilerplate"
        if lxc start -q "${container_name}" &>/dev/null; then
            sleep 5 # guest needs some time to come up and get an IP
        fi
        if [[ -n "${boilerplate_script}" ]]; then
            echo "${boilerplate_script}" \
                | lxc exec "${container_name}" -- bash \
                | prefix_stdout "[${_BBlue}${container_name}${_creset}] "
        else
            err_msg "[${_BBlue}${container_name}${_creset}] no boilerplate for image '${image_name}'"
        fi

    done
}

lxc_delete_containers() {
    for i in "${LOCAL_IMAGES[@]}"; do
        if lxc info "$i" &>/dev/null; then
            info_msg "stop & delete instance ${_BBlue}${i}${_creset}"
            lxc stop "$i" &>/dev/null
            lxc delete "$i" | prefix_stdout
        else
            warn_msg "instance '$i' does not exist / can't delete :o"
        fi
    done
}

# subordinates
# ------------
#
# see man: subgid(5), subuid(5), https://lxd.readthedocs.io/en/latest/userns-idmap
#
# E.g. in the HOST you have uid=1001(user) and/or gid=1001(user) ::
#
#   root:1001:1
#
# in the CONTAINER::
#
#   config:
#     raw.idmap: |
#       uid 1001 1000
#       gid 1001 1000

add_subordinate_ids() {
    if  grep "root:${HOST_USER_ID}:1" /etc/subuid -qs; then
        info_msg "lxd already has permission to map ${HOST_USER_ID}'s user/group id through"
    else
        info_msg "add lxd permission to map ${HOST_USER_ID}'s user/group id through"
        usermod --add-subuids "${HOST_USER_ID}-${HOST_USER_ID}" \
                --add-subgids "${HOST_GROUP_ID}-${HOST_GROUP_ID}" root
    fi
}

del_subordinate_ids() {
    local out
    local exit_val
    if  grep "root:${HOST_USER_ID}:1" /etc/subuid -qs; then
        # TODO: root user is always in use by process 1, how can we remove subordinates?
        info_msg "remove lxd permission to map ${HOST_USER_ID}'s user/group id through"
        out=$(usermod --del-subuids "${HOST_USER_ID}-${HOST_USER_ID}" --del-subgids "${HOST_GROUP_ID}-${HOST_GROUP_ID}" root 2>&1)
        exit_val=$?
        if [ $exit_val -ne 0 ]; then
            err_msg "$out"
        fi
    else
        info_msg "lxd does not have permission to map ${HOST_USER_ID}'s user/group id through"
    fi
}


# ----------------------------------------------------------------------------
main "$@"
# ----------------------------------------------------------------------------
