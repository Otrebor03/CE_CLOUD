#!/bin/bash
# Datos de usuario de webmin-rr-template (v3)
set -e
# 1. Obtener el nombre de la instancia mediante IMDSv2
IMDS="http://169.254.169.254/latest"
TOKEN=$(curl -fsS -X PUT "$IMDS/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
NOMBRE=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/tags/instance/Name")
if [ -z "$NOMBRE" ]; then
  echo "ERROR: No se ha podido obtener la etiqueta Name"
  exit 1
fi
# 2. Configurar el nombre de host
hostnamectl set-hostname "$NOMBRE"
echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-hostname.cfg
# 3. Instalar Webmin desde su repositorio oficial
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl gpg apt-transport-https openssl
if ! grep -Rqs "download.webmin.com" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  curl -fsSL --retry 5 https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh -o /tmp/webmin-setup-repo.sh
  sh /tmp/webmin-setup-repo.sh --force
fi
apt-get update
apt-get install -y webmin
systemctl enable --now webmin
# 4. Generar contraseña aleatoria solo si no existe
if [ ! -f /root/webmin-pass.txt ]; then
  WEBMIN_PASS=$(openssl rand -hex 24)
  /usr/share/webmin/changepass.pl /etc/webmin root "$WEBMIN_PASS"
  printf '%s\n' "$WEBMIN_PASS" > /root/webmin-pass.txt
  chmod 600 /root/webmin-pass.txt
  chown root:root /root/webmin-pass.txt
  unset WEBMIN_PASS
fi
echo "Configuración de Webmin completada correctamente"