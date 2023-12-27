#!/usr/bin/env bash

# Debug this script if in debug mode
(( $DEBUG == 1 )) && set -x

# Import dsip_lib utility / shared functions if not already
if [[ "$DSIP_LIB_IMPORTED" != "1" ]]; then
    . ${DSIP_PROJECT_DIR}/dsiprouter/dsip_lib.sh
fi

function install() {
    # create nginx user and group
    # sometimes locks aren't properly removed (this seems to happen often on VM's)
    rm -f /etc/passwd.lock /etc/shadow.lock /etc/group.lock /etc/gshadow.lock &>/dev/null
    userdel nginx &>/dev/null; groupdel nginx &>/dev/null
    useradd --system --user-group --shell /bin/false --comment "nginx HTTP Service Provider" nginx

    dnf install -y nginx

    if (( $? != 0 )); then
        return 1
    fi

    # setup runtime directorys for nginx
    mkdir -p /run/nginx
    chown -R nginx:nginx /run/nginx

    # give nginx permissions in SELINUX
    semanage port -a -t http_port_t -p tcp ${DSIP_PORT} ||
    semanage port -m -t http_port_t -p tcp ${DSIP_PORT}
    # NOTE: /var/run is required here due to the aliasing in the fcontexts
    #semanage fcontext -a -t httpd_var_run_t '/var/run/dsiprouter/dsiprouter\.sock'
    # TODO: this is a workaround, this the "wrong" way to do it
    # we need to figure out why the fcontexts are not applying by default to new files
    # and possibly (preferably) create our own type with those specific permissions
    # for example a new type dsiprouter_run_t labeled on '/var/run/dsiprouter/.+'
    (
        if semodule -l | grep -q 'dsiprouter'; then
            semodule -r dsiprouter
        fi
        cd /tmp &&
        checkmodule -M -m -o dsiprouter.mod ${DSIP_PROJECT_DIR}/nginx/selinux/centos.te &&
        semodule_package -o dsiprouter.pp -m dsiprouter.mod &&
        semodule -i dsiprouter.pp
    )
    if (( $? != 0 )); then
        printerr 'failed updating selinux permissions'
        return 1
    fi

    # Configure nginx
    # determine available TLS protocols (try using highest available)
    OPENSSL_VER=$(openssl version 2>/dev/null | awk '{print $2}' | perl -pe 's%([0-9])\.([0-9]).([0-9]).*%\1\2\3%')
    if (( ${OPENSSL_VER} < 101 )); then
        TLS_PROTOCOLS="TLSv1"
    elif (( ${OPENSSL_VER} < 111 )); then
        TLS_PROTOCOLS="TLSv1.1 TLSv1.2"
    else
        TLS_PROTOCOLS="TLSv1.2 TLSv1.3"
    fi
    mkdir -p /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/nginx.conf.d/
    # remove the defaults
    rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /etc/nginx/nginx.conf.d/*
    # setup our own nginx configs
    perl -e "\$tls_protocols='${TLS_PROTOCOLS}';" \
        -pe 's%TLS_PROTOCOLS%${tls_protocols}%g;' \
        ${DSIP_PROJECT_DIR}/nginx/configs/nginx.conf >/etc/nginx/nginx.conf

    # configure nginx systemd service
    cp -f ${DSIP_PROJECT_DIR}/nginx/systemd/nginx-stop.sh /usr/sbin/nginx-stop
    cp -f ${DSIP_PROJECT_DIR}/nginx/systemd/nginx-v2.service /lib/systemd/system/nginx.service
    cp -f ${DSIP_PROJECT_DIR}/nginx/systemd/nginx-watcher-v2.service /lib/systemd/system/nginx-watcher.service
    perl -p \
        -e "s%PathChanged\=.*%PathChanged=${DSIP_CERTS_DIR}/%;" \
        ${DSIP_PROJECT_DIR}/nginx/systemd/nginx-watcher.path >/lib/systemd/system/nginx-watcher.path
    chmod 644 /lib/systemd/system/nginx.service
    chmod 644 /lib/systemd/system/nginx-watcher.service
    chmod 644 /lib/systemd/system/nginx-watcher.path
    systemctl daemon-reload
    systemctl enable nginx

    return 0
}

function uninstall() {
    # stop nginx and remove nginx package
    systemctl stop nginx
    systemctl disable nginx
    dnf remove -y nginx

    # remove nginx systemd service
    rm -f /usr/sbin/nginx-stop
    rm -f /lib/systemd/system/nginx.service
    rm -f /lib/systemd/system/nginx-watcher.service
    rm -f /lib/systemd/system/nginx-watcher.path
    systemctl daemon-reload

    # remove SELINUX permissions
    semanage port -d -t http_port_t -p tcp ${DSIP_PORT}

    return 0
}

case "$1" in
    uninstall)
        uninstall && exit 0 || exit 1
        ;;
    install)
        install && exit 0 || exit 1
        ;;
    *)
        printerr "usage $0 [install | uninstall]"
        exit 1
        ;;
esac
