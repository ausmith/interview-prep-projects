#!/usr/bin/env bash

if [ -z "$1" ] ; then
  echo "No role (proxy|webserver-a|webserver-b) provided"
  exit 1
fi
server_role=$1
if [[ "$server_role" =~ (proxy|webserver-a|webserver-b) ]] ; then
  echo "Setting up freenginx for role: ${server_role}"
else
  echo "Did not receive an expected role (proxy|webserver-a|webserver-b), bailing"
  exit 1
fi

# Choosing freenginx over nginx, but unfortunately this means we don't have a package available for quick install
# Following https://ubuntushell.com/install-freenginx/ guide for the install process
sudo apt install -y wget build-essential libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev libgd-dev libxml2 libxml2-dev uuid-dev
# Confirm that nginx package is not installed else we'll need to purge it to avoid conflicts with freenginx
if apt list --installed | grep -q nginx ; then
  sudo apt --purge remove nginx-*
  sudo apt autoremove
fi

# Since we have already checked if the nginx package is installed, any running nginx is installed from source,
#   allowing us to skip some of the below install steps
if ! which nginx ; then
  # Download current release and unpack the tarball to a temp directory
  current_release="1.26.0"
  url_prefix="https://freenginx.org/download"
  tarball="freenginx-${current_release}.tar.gz"
  # Clean previous downloads and unpacks for safety
  rm -f "/tmp/freenginx*"
  wget "${url_prefix}/${tarball}" -P /tmp
  tar -zxvf "/tmp/${tarball}" -C /tmp

  # Configure freenginx (which still uses the `nginx` name for many of its file locations)
  pushd "/tmp/freenginx-${current_release}"
  # This configuration pulled straight from the guide
  ./configure --prefix=/var/www/html --sbin-path=/usr/sbin/nginx \
    --conf-path=/etc/nginx/nginx.conf --http-log-path=/var/log/nginx/access.log \
    --error-log-path=/var/log/nginx/error.log --with-pcre \
    --lock-path=/var/lock/nginx.lock --pid-path=/var/run/nginx.pid \
    --with-http_ssl_module --with-http_image_filter_module=dynamic \
    --modules-path=/etc/nginx/modules --with-http_v2_module \
    --with-stream=dynamic --with-http_addition_module \
    --with-http_mp4_module
  make
  sudo make install
  popd # return to directory user was operating in before
fi

# Make sure nginx is installed and then that it's stopped before setting up systemctl
if ! nginx -v ; then
  echo "nginx seems to not have installed as expected"
  exit 1
fi

# Setup systemctl for freenginx
if ! systemctl status nginx ; then
  if pgrep nginx ; then
    # Must be running as a bare process, possibly from the install
    nginx -s stop || true
  fi

  # Write the systemctl config
  sudo tee /lib/systemd/system/nginx.service <<'EOF'
[Unit]
Description=The Freenginx HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/usr/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  # Start freenginx
  sudo systemctl start nginx
  # Enable autostart for freenginx
  sudo systemctl enable nginx
fi

if [[ $server_role == "webserver-a" ]] || [[ $server_role == "webserver-b" ]] ; then
  body=""
  if [[ $server_role == "webserver-a" ]] ; then
    body="a"
  elif [[ $server_role == "webserver-b" ]] ; then
    body="b"
  else
    body="Neither webserver-a or webserver-b..."
  fi
  sudo tee /var/www/html/html/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<title>Welcome!</title>
</head>
<body>
<p>${body}</p>
</body>
</html>
EOF
elif [[ $server_role == "proxy" ]] ; then
  echo "Have not figured out proxy code yet"
fi
