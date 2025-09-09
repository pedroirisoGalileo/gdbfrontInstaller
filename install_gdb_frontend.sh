#!/bin/bash

# Variables
REPO_URL="https://github.com/pedroirisoGalileo/gdbfrontInstaller.git"
TARGET_HOME="/home/tareas"
STUDENT_USER="tareas"

# Clonar repositorio
git clone "$REPO_URL" /tmp/gdbfrontInstaller

# Dar permisos de ejecución a los scripts
chmod +x /tmp/gdbfrontInstaller/*.sh

# Ejecutar el instalador con los parámetros dados
sudo bash /tmp/gdbfrontInstaller/deploy_gdb_frontend.sh \
  --target-home "$TARGET_HOME" \
  --student-user "$STUDENT_USER" \
  --verbose

# Copiar el archivo debug-frontend.sh al home del usuario tareas
cp /tmp/gdbfrontInstaller/debug-frontend.sh "$TARGET_HOME/"

# Cambiar propietario y dar permisos de escritura
sudo chown "$STUDENT_USER":"$STUDENT_USER" "$TARGET_HOME/debug-frontend.sh"
sudo chmod u+w "$TARGET_HOME/debug-frontend.sh"
