#!/bin/bash
#set -u # warn undefined variables
# vim:ts=2:sw=2:sts=0:number:expandtab

# Automatic Xrdp/X11rdp Compiler/Installer
# a.k.a. ScaryGliders X11rdp-O-Matic
#
# Version 3.11
#
# Version release date : 20140927
########################(yyyyMMDD)
#
# Will run on Debian-based systems only at the moment. RPM based distros perhaps some time in the future...
#
# Copyright (C) 2012-2014, Kevin Cave <kevin@scarygliders.net>
# With contributions and suggestions from other kind people - thank you!
#
# ISC License (ISC)
#
# Permission to use, copy, modify, and/or distribute this software for any purpose with
# or without fee is hereby granted, provided that the above copyright notice and this
# permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO
# THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
# DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
# AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION
# WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
export LANG=C
trap user_interrupt_exit SIGINT

if [ $UID -eq 0 ] ; then
  # write to stderr 1>&2
  echo "${0}:  Never run this utility as root." 1>&2
  echo 1>&2
  echo "This script will gain root privileges via sudo on demand, then type your password." 1>&2
  exit 1
fi

if ! hash sudo 2> /dev/null ; then
  # write to stderr 1>&2
  echo "${0}: sudo not found." 1>&2
  echo 1>&2
  echo 'This utility requires sudo to gain root privileges on demand.' 1>&2
  echo 'run `apt-get install sudo` in root privileges before run this utility.' 1>&2
  exit 1
fi

LINE="----------------------------------------------------------------------"

# xrdp repository
: ${GH_ACCOUNT:=neutrinolabs}
: ${GH_PROJECT:=xrdp}
: ${GH_BRANCH:=master}
GH_URL=https://github.com/${GH_ACCOUNT}/${GH_PROJECT}.git
# xorgxrdp repository
: ${GH_ACCOUNT_xorgxrdp:=neutrinolabs}
: ${GH_PROJECT_xorgxrdp:=xorgxrdp}
: ${GH_BRANCH_xorgxrdp:=master}
GH_URL_xorgxrdp=https://github.com/${GH_ACCOUNT_xorgxrdp}/${GH_PROJECT_xorgxrdp}.git

# working directories and logs
WRKDIR=$(mktemp --directory --suffix .X11RDP-o-Matic)
BASEDIR=$(dirname $(readlink -f $0))
PKGDIR=${BASEDIR}/packages
PATCHDIR=${BASEDIR}/patches
PIDFILE=${BASEDIR}/.PID
APT_LOG=${WRKDIR}/apt.log
BUILD_LOG=${WRKDIR}/build.log
SUDO_LOG=${WRKDIR}/sudo.log

# packages to run this utility
META_DEPENDS=(lsb-release rsync git build-essential dh-make wget gdebi)
XRDP_CONFIGURE_ARGS=(--prefix=/usr --sysconfdir=/etc --localstatedir=/var --enable-fuse --enable-jpeg --enable-opus)
XRDP_BUILD_DEPENDS=(debhelper autoconf automake dh-systemd libfuse-dev libjpeg-dev libopus-dev libpam0g-dev libssl-dev libtool libx11-dev libxfixes-dev libxrandr-dev pkg-config)
X11RDP_BUILD_DEPENDS=(autoconf automake libtool flex bison python-libxml2 libxml2-dev gettext intltool xsltproc make gcc g++ xutils-dev xutils)
XORGXRDP_BUILD_DEPENDS=(automake autoconf libtool pkg-config nasm xserver-xorg-dev xserver-xorg-core x11-utils)

ARCH=$(dpkg --print-architecture)
RELEASE=1 # release number for debian packages
X11RDPBASE=/opt/X11rdp

# flags
PARALLELMAKE=true   # Utilise all available CPU's for compilation by default.
CLEANUP=false       # Keep the x11rdp and xrdp sources by default - to remove
                    # requires --cleanup command line switch
INSTALL_PKGS=true   # Install xrdp and x11rdp on this system
MAINTAINER=false    # maintainer mode
BUILD_X11RDP=true   # Build and package x11rdp
GIT_USE_HTTPS=true  # Use firewall-friendry https:// instead of git:// to fetch git submodules

# check if the system is using systemd or not
[ -z "$(pidof systemd)" ] && \
  USING_SYSTEMD=false || \
  USING_SYSTEMD=true

# libtool binaries are separated to libtool-bin package since Ubuntu 15.04
# if libtool-bin package exists, add it to REQUIREDPACKAGES
apt-cache search ^libtool-bin | grep -q libtool-bin && \
  REQUIREDPACKAGES+=(libtool-bin) XRDP_BUILD_DEPENDS+=(libtool-bin) X11RDP_BUILD_DEPENDS+=(libtool-bin)

# add apt-utils if found in repository
apt-cache search ^apt-utils$ | grep -q ^apt-utils && \
  META_DEPENDS=(apt-utils "${META_DEPENDS[@]}")

#############################################
# Common function declarations begin here...#
#############################################

SUDO_CMD()
{
  # sudo's password prompt timeouts 5 minutes by most default settings
  # to avoid exit this script because of sudo timeout
  echo_stderr
  # not using echo_stderr here because output also be written $SUDO_LOG
  echo "Following command will be executed via sudo:" | tee -a $SUDO_LOG 1>&2
  echo "	$@" | tee -a $SUDO_LOG 1>&2
  while ! sudo -v; do :; done
  sudo DEBIAN_FRONTEND=noninteractive $@ | tee -a $SUDO_LOG
  return ${PIPESTATUS[0]}
}

echo_stderr()
{
  echo $@ 1>&2
}

error_exit()
{
  echo_stderr; echo_stderr
  echo_stderr "Oops, something going wrong around line: $BASH_LINENO"
  echo_stderr "See logs to get further information:"
  echo_stderr "	$BUILD_LOG"
  echo_stderr "	$SUDO_LOG"
  echo_stderr "	$APT_LOG"
  echo_stderr "Exitting..."
  if ${MAINTAINER}; then
    echo_stderr
    echo_stderr 'Maintainer mode detected, showing build log...'
    echo_stderr
    tail -n 100 ${BUILD_LOG} 1>&2
    echo_stderr
  fi
  [ -f "${PIDFILE}" ] && [ "$(cat "${PIDFILE}")" = $$ ] && rm -f "${PIDFILE}"
  exit 1
}

clean_exit()
{
  [ -f "${PIDFILE}" ] && [ "$(cat "${PIDFILE}")" = $$ ] && rm -f "${PIDFILE}"
  exit 0
}

user_interrupt_exit()
{
  echo_stderr; echo_stderr
  echo_stderr "Script stopped due to user interrupt, exitting..."
  cd "$BASEDIR"
  [ -f "${PIDFILE}" ] && [ "$(cat "${PIDFILE}")" = $$ ] && rm -f "${PIDFILE}"
  exit 1
}

# call like this: install_required_packages ${PACKAGES[@]}
install_required_packages()
{
  for f in $@
  do
    echo -n "Checking for ${f}... "
    check_if_installed $f
    if [ $? -eq 0 ]; then
      echo "yes"
    else
      echo "no"
      echo -n "Installing ${f}... "
      SUDO_CMD apt-get -y install $f >> $APT_LOG && echo "done" || error_exit
    fi
  done
}

# check if given package is installed
check_if_installed()
{
  # if not installed, the last command's exit code will be 1
  dpkg-query -W --showformat='${Status}\n' "$1" 2>/dev/null  \
    | grep -v -q -e "deinstall ok" -e "not installed"  -e "not-installed"
}

install_package()
{
  SUDO_CMD apt-get -y install "$1" >> $APT_LOG || error_exit
}

# change dh_make option depending on if dh_make supports -y option
dh_make_y()
{
  dh_make -h | grep -q -- -y && \
    DH_MAKE_Y=true || DH_MAKE_Y=false

  if $DH_MAKE_Y
  then
    dh_make -y $@
  else
    echo | dh_make $@
  fi
}

# Get list of available branches from remote git repository
get_branches()
{
  echo $LINE
  echo "Obtaining list of available branches..."
  echo $LINE
  BRANCHES=$(git ls-remote --heads "$GH_URL" | cut -f2 | cut -d "/" -f 3)
  echo $BRANCHES
  echo $LINE
}

install_targets_depends()
{
  install_required_packages ${XRDP_BUILD_DEPENDS[@]} ${XORGXRDP_BUILD_DEPENDS[@]}
  $BUILD_X11RDP && install_required_packages ${X11RDP_BUILD_DEPENDS[@]}
}

first_of_all()
{
  if [ -f "${PIDFILE}" ]; then
    echo_stderr "Another instance of $0 is already running." 2>&1
    error_exit
  else
    echo $$ > "${PIDFILE}"
  fi

  echo 'Allow X11RDP-o-Matic to gain root privileges.'
  echo 'Type your password if required.'
  sudo -v

  SUDO_CMD apt-get update >> $APT_LOG || error_exit
}

parse_commandline_args()
{
# If first switch = --help, display the help/usage message then exit.
  if [ $1 = "--help" ]
  then
    echo "usage: $0 OPTIONS

OPTIONS
-------
  --help             : show this help.
  --branch <branch>  : use one of the available xrdp branches listed below...
                       Examples:
                       --branch v0.8    - use the 0.8 branch.
                       --branch master  - use the master branch. <-- Default if no --branch switch used.
                       --branch devel   - use the devel branch (Bleeding Edge - may not work properly!)
                       Branches beginning with "v" are stable releases.
                       The master branch changes when xrdp authors merge changes from the devel branch.
  --nocpuoptimize    : do not change X11rdp build script to utilize more than 1 of your CPU cores.
  --cleanup          : remove X11rdp / xrdp source code after installation. (Default is to keep it).
  --noinstall        : do not install anything, just build the packages
  --nox11rdp         : only build xrdp, do not build the x11rdp backend
  --withdebug        : build with debug enabled
  --withneutrino     : build the neutrinordp module
  --withkerberos     : build support for kerberos
  --withxrdpvr       : build the xrdpvr module
  --withnopam        : don't include PAM support
  --withpamuserpass  : build with pam userpass support
  --withfreerdp      : build the freerdp1 module"
    get_branches
    rmdir "${WRKDIR}"
    exit
  fi

  # Parse the command line for any arguments
  while [ $# -gt 0 ]; do
  case "$1" in
    --branch)
      get_branches
      ok=0
      for check in ${BRANCHES[@]}
      do
        if [ "$check" = "$2" ]
        then
          ok=1
        fi
      done
      if [ $ok -eq 0 ]
      then
        echo "**** Error detected in branch selection. Argument after --branch was : $2 ."
        echo "**** Available branches : "$BRANCHES
        exit 1
      fi
      GH_BRANCH="$2"
      echo "Using branch ==>> ${GH_BRANCH} <<=="
      if [ "$GH_BRANCH" = "devel" ]
      then
        echo "Note : using the bleeding-edge version may result in problems :)"
      fi
      echo $LINE
      shift
      ;;
    --nocpuoptimize)
      PARALLELMAKE=false
      ;;
    --cleanup)
      CLEANUP=true
      ;;

    --maintainer)
      MAINTAINER=true
      ;;

    --noinstall)
      INSTALL_PKGS=false
      ;;
    --nox11rdp)
      BUILD_X11RDP=false
      ;;
    --withdebug)
      XRDP_CONFIGURE_ARGS+=(--enable-xrdpdebug)
      ;;
    --withneutrino)
      XRDP_CONFIGURE_ARGS+=(--enable-neutrinordp)
      ;;
    --withkerberos)
      XRDP_CONFIGURE_ARGS+=(--enable-kerberos)
      ;;
    --withxrdpvr)
      XRDP_CONFIGURE_ARGS+=(--enable-xrdpvr)
      XRDP_BUILD_DEPENDS+=(libavcodec-dev libavformat-dev)
      ;;
    --withnopam)
      XRDP_CONFIGURE_ARGS+=(--disable-pam)
      ;;
    --withpamuserpass)
      XRDP_CONFIGURE_ARGS+=(--enable-pamuserpass)
      ;;
    --withfreerdp)
      XRDP_CONFIGURE_ARGS+=(--enable-freerdp1)
      XRDP_BUILD_DEPENDS+=(libfreerdp-dev)
      ;;
  esac
  shift
  done
}

clone()
{
  local CLONE_DEST="${WRKDIR}/xrdp"
  local CLONE_DEST_xorgxrdp="${CLONE_DEST}/xorgxrdp"

  echo -n 'Cloning xrdp source code... '

  if [ ! -d "$CLONE_DEST" ]; then
    if $GIT_USE_HTTPS; then
      git clone ${GH_URL} --branch ${GH_BRANCH} ${CLONE_DEST} >> $BUILD_LOG 2>&1 || error_exit
      sed -i -e 's|git://|https://|' ${CLONE_DEST}/.gitmodules ${CLONE_DEST}/.git/config
      (cd $CLONE_DEST && git submodule update --init --recursive) >> $BUILD_LOG 2>&1
    else
      git clone --resursive ${GH_URL} --branch ${GH_BRANCH} ${CLONE_DEST} >> $BUILD_LOG 2>&1 || error_exit
    fi
    # if commit hash specified, use it
    if [ -n "${GH_COMMIT}" ]; then
      (cd $CLONE_DEST && git reset --hard "${GH_COMMIT}" ) >> $BUILD_LOG 2>&1 || error_exit
    fi
    echo 'done'
  else
    echo 'already exists'
  fi

  echo -n 'Cloning xorgxrdp source code... '
  if [ ! -d "$CLONE_DEST_xorgxrdp" ]; then
    git clone ${GH_URL_xorgxrdp} --branch ${GH_BRANCH_xorgxrdp} ${CLONE_DEST_xorgxrdp} \
      >> $BUILD_LOG 2>&1 || error_exit

    # if commit hash specified, use it
    if [ -n "${GH_COMMIT_xorgxrdp}" ]; then
      (cd ${CLONE_DEST_xorgxrdp} && git reset --hard "${GH_COMMIT_xorgxrdp}" \
        >> $BUILD_LOG 2>&1 || error_exit)
    fi
    echo 'done'
  else
    echo 'already exists'
  fi
}

compile_X11rdp()
{
  cd "$WRKDIR/xrdp/xorg/X11R7.6/"
  SUDO_CMD sh buildx.sh "$X11RDPBASE" >> $BUILD_LOG 2>&1 || error_exit
}

package_X11rdp()
{
  X11RDP_DEB="x11rdp_${X11RDP_VERSION}-${RELEASE}_${ARCH}.deb"

  if [ -f "$WRKDIR/xrdp/xorg/debuild/debX11rdp.sh" ]
  then
    cd "$WRKDIR/xrdp/xorg/debuild"
    ./debX11rdp.sh "$X11RDP_VERSION" "$RELEASE" "$X11RDPBASE" "$WRKDIR" || error_exit
  fi

  cp "${WRKDIR}/${X11RDP_DEB}" "${PKGDIR}" || error_exit

  if [ -d "${X11RDPBASE}" ]; then
    SUDO_CMD find "${X11RDPBASE}" -delete
  fi
}

# Compile and make xrdp package
compile_xrdp()
{
  XRDP_DEB="xrdp_${XRDP_VERSION}-${RELEASE}_${ARCH}.deb"
  XORGXRDP_DEB="xorgxrdp_${XRDP_VERSION}-${RELEASE}_${ARCH}.deb"

  echo "Using the following xrdp configuration: "
  echo "	"${XRDP_CONFIGURE_ARGS[@]}

  # Step 1: Link xrdp dir to xrdp-$VERSION for dh_make to work on...
  rsync -a --delete -- "${WRKDIR}/xrdp/" "${WRKDIR}/xrdp-${XRDP_VERSION}"

  # Step 2 : Use dh-make to create the debian directory package template...
  cd "${WRKDIR}/xrdp-${XRDP_VERSION}"
  dh_make_y --single --copyright apache --createorig >> $BUILD_LOG 2>&1 || error_exit

  # Step 3 : edit/configure the debian directory...
  rm debian/*.{ex,EX} debian/README.{Debian,source}
  cp "${BASEDIR}/debian/"{control,docs,postinst,prerm,install,socksetup,startwm.sh} debian/
  #
  # not copying patches here because dpkg-source doesn't accept any fuzz
  # patches in debian/patches directory are applied in alter_xrdp_source()
  #
  # cp -r "${BASEDIR}/debian/"patches debian/
  #
  cp COPYING debian/copyright
  cp README.md debian/README
  sed -e "s|%%XRDP_CONFIGURE_ARGS%%|${XRDP_CONFIGURE_ARGS[*]}|g" \
       "${BASEDIR}/debian/rules.in" > debian/rules
  chmod 0755 debian/rules

  # Step 4 : run dpkg-buildpackage to compile xrdp and build a package...
  dpkg-buildpackage -uc -us -tc -rfakeroot >> $BUILD_LOG  2>&1 || error_exit
  cp "${WRKDIR}/${XRDP_DEB}" "${PKGDIR}" || error_exit
  cp "${WRKDIR}/${XORGXRDP_DEB}" "${PKGDIR}" || error_exit
}

# cpu cores utilization has been merged in devel
# TO BE DELETED
utilize_all_cpus()
{
  $PARALLELMAKE || return

  Cores=$(nproc)
  if [ $Cores -gt 1 ]
  then
    sed -i -e "s/make -C/make -j ${Cores} -C/g" "${WRKDIR}/xrdp/xorg/X11R7.6/buildx.sh"
  fi
}

# bran new version calculation
# new version number includes git last commit date, hash and branch.
bran_new_calculate_version_num()
{
  clone
  local _PWD=$PWD
  cd ${WRKDIR}/xrdp || error_exit
  local _XRDP_VERSION=$(<${WRKDIR}/xrdp/configure.ac grep ^AC_INIT | sed -e 's|AC_INIT(\[\(.*\)\], \[\(.*\)\], \[\(.*\)\])|\2|')
  local _XRDP_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  # hack for git 2.1.x
  # in latest git, this can be written: git log -1 --date=format:%Y%m%d --format="~%cd+git%h" .
  local _XRDP_DATE_HASH=$(git log -1 --date=short --format="~%cd+git%h" . | tr -d -)
  local _X11RDP_DATE_HASH=$(git log -1 --date=short --format="~%cd+git%h" xorg/X11R7.6 | tr -d -)
  #local _XORGXRDP_DATE_HASH=$(cd xorgxrdp; git log -1 --date=short --format="~%cd+git%h" . | tr -d -)
  cd ${_PWD} || error_exit

  XRDP_VERSION=${_XRDP_VERSION}${_XRDP_DATE_HASH}+${_XRDP_BRANCH}
  X11RDP_VERSION=${_XRDP_VERSION}${_X11RDP_DATE_HASH}+${_XRDP_BRANCH}
  #XORGXRDP_VERSION=${_XRDP_VERSION}${_XORGXRDP_DATE_HASH}+${_XRDP_BRANCH}
  XORGXRDP_VERSION=${XRDP_VERSION}

  echo -e "\t" xrdp=${XRDP_VERSION}
  echo -e "\t" x11rdp=${X11RDP_VERSION}
  echo -e "\t" xorgxrdp=${XORGXRDP_VERSION}
}

# Make a directory, to which the X11rdp build system will
# place all the built binaries and files.
make_X11rdp_env()
{
  $BUILD_X11RDP || return

  if [ -e "$X11RDPBASE" -a "$X11RDPBASE" != "/" ]
  then
    remove_installed_packages x11rdp
    SUDO_CMD rm -rf "$X11RDPBASE" || error_exit
    SUDO_CMD mkdir -p "$X11RDPBASE" || error_exit
  fi
}

# apply patches not using dpkg-source
alter_xrdp_source()
{
  cd "$WRKDIR"

  # install systemd files
  cp ${BASEDIR}/files/*.service ${WRKDIR}/xrdp/instfiles/

  # Patch rdp Makefile
  patch -b -d "$WRKDIR/xrdp/xorg/X11R7.6/rdp" Makefile < "$PATCHDIR/rdp_Makefile.patch" >> $BUILD_LOG  || error_exit

  # do not use dpkg-source to apply patches because it doesn't accept any fuzz
  while read p
  do
    patch \
      -d "${WRKDIR}/xrdp" \
      -p1 --batch --forward --unified  --version-control never \
      --remove-empty-files --backup < "${BASEDIR}/debian/patches/${p}" \
      >> $BUILD_LOG 2>&1 || error_exit
  done < "${BASEDIR}/debian/patches/series"
}

install_generated_packages()
{
  $INSTALL_PKGS || return # do nothing if "--noinstall"

  if ${BUILD_X11RDP}; then
    remove_installed_packages x11rdp
    echo -n 'Installing built x11rdp... '
    SUDO_CMD gdebi --n "${PKGDIR}/${X11RDP_DEB}" >> $APT_LOG || error_exit
    echo 'done'
  fi

  remove_installed_packages xorgxrdp xrdp
  echo -n 'Installing built xorgxrdp... '
  SUDO_CMD gdebi --n "${PKGDIR}/${XORGXRDP_DEB}" >> $APT_LOG || error_exit
  echo 'done'
  echo -n 'Installing built xrdp... '
  SUDO_CMD gdebi --n "${PKGDIR}/${XRDP_DEB}" >> $APT_LOG || error_exit
  echo 'done'
}

build_dpkg()
{
  alter_xrdp_source # apply patches

  echo 'Building packages started, please be patient...'
  echo 'Do the following command to see build progress.'
  echo "	$ tail -f $BUILD_LOG"
  compile_xrdp # Compiles & packages using dh_make and dpkg-buildpackage

  # build and make x11rdp package
  if $BUILD_X11RDP
  then
    utilize_all_cpus
    make_X11rdp_env
    compile_X11rdp
    package_X11rdp
  fi

  echo "Built packages are located in ${PKGDIR}."
  ls -1 \
    ${PKGDIR}/${XRDP_DEB} \
    ${PKGDIR}/${XORGXRDP_DEB}

  if $BUILD_X11RDP
  then
    ls -1 \
      ${PKGDIR}/${X11RDP_DEB}
  fi
}

remove_installed_packages()
{
  for f in $@; do
    echo -n "Removing installed ${f}... "
    check_if_installed ${f}
    if [ $? -eq 0 ]; then
      SUDO_CMD apt-get -y remove ${f} >> $APT_LOG || error_exit
    fi
    echo "done"
  done
}

check_for_opt_directory()
{
  $BUILD_X11RDP || return
  if [ ! -e /opt ]
  then
    echo "Did not find a /opt directory... creating it."
    echo $LINE
    SUDO_CMD mkdir /opt || error_exit
  fi
}

cleanup()
{
  $CLEANUP || return
  echo -n "Cleaning up working directory: ${WRKDIR} ... "
  rm -rf "$WRKDIR"
  echo "done"
}

##########################
# Main stuff starts here #
##########################

parse_commandline_args $@
first_of_all
install_required_packages ${META_DEPENDS[@]} # install packages required to run this utility
check_for_opt_directory # Check for existence of a /opt directory, and create it if it doesn't exist.
bran_new_calculate_version_num
install_targets_depends
build_dpkg
cleanup
install_generated_packages
echo; echo 'Everything is done!'
clean_exit
