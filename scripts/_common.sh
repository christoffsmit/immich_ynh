#!/bin/bash

#=================================================
# COMMON VARIABLES
#=================================================

if [[ ${BASH_SOURCE[0]} == "../settings/"* ]]
then
	manifest_path="../settings/manifest.toml"
else
	manifest_path="../manifest.toml"
fi

# App version
## yq is not a dependencie of yunohost package so tomlq command is not available
## (see https://github.com/YunoHost/yunohost/blob/dev/debian/control)
app_version=$(cat "$manifest_path" 2>/dev/null \
				| grep 'version = ' | cut -d '=' -f 2 \
				| cut -d '~' -f 1 | tr -d ' "') #2024.2.5
app_version="v$app_version"

# NodeJS required version
nodejs_version=20

# PostgreSQL required version
postgresql_version=$(cat "$manifest_path" 2>/dev/null \
						| grep -o 'postgresql-[0-9][0-9]-pgvector' \
						| head -n1 | cut -d'-' -f2) #16

# Fail2ban
failregex="immich-server.*Failed login attempt for user.+from ip address\s?<ADDR>"

#=================================================
# PERSONAL HELPERS
#=================================================

# Retrieve full latest python version from major version
# usage: py_latest_from_major --python="3.8"
# | arg: -p, --python=    - the major python version
myynh_py_latest_from_major() {
	# Declare an array to define the options of this helper.
	local legacy_args=u
	local -A args_array=( [p]=python= )
	local python
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"

	py_required_version=$(curl -Ls https://www.python.org/ftp/python/ \
						| grep '>'$python  | cut -d '/' -f 2 \
						| cut -d '>' -f 2 | sort -rV | head -n 1)
}

# Install specific python version
# usage: myynh_install_python --python="3.8.6"
# | arg: -p, --python=    - the python version to install
myynh_install_python() {
	# Declare an array to define the options of this helper.
	local legacy_args=u
	local -A args_array=( [p]=python= )
	local python
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"

	# Check python version from APT
	local py_apt_version=$(python3 --version | cut -d ' ' -f 2)

	# Usefull variables
	local python_major=${python%.*}

	# Check existing built version of python in /usr/local/bin
	if [ -e "/usr/local/bin/python$python_major" ]
	then
		local py_built_version=$(/usr/local/bin/python$python_major --version \
			| cut -d ' ' -f 2)
	else
		local py_built_version=0
	fi

	# Compare version
	if $(dpkg --compare-versions $py_apt_version ge $python)
	then
		# APT >= Required
		ynh_print_info --message="Using provided python3..."

		py_app_version="python3"

	else
		# Either python already built or to build
		if $(dpkg --compare-versions $py_built_version ge $python)
		then
			# Built >= Required
			ynh_print_info --message="Using already used python3 built version..."

			py_app_version="/usr/local/bin/python${py_built_version%.*}"

		else
			# APT < Minimal & Actual < Minimal => Build & install Python into /usr/local/bin
			ynh_print_info --message="Building python (may take a while)..."

			# Store current direcotry
			local MY_DIR=$(pwd)

			# Create a temp direcotry
			tmpdir_py="$(mktemp --directory)"
			cd "$tmpdir_py"

			# Download
			wget --output-document="Python-$python.tar.xz" \
				"https://www.python.org/ftp/python/$python/Python-$python.tar.xz" 2>&1

			# Extract
			tar xf "Python-$python.tar.xz"

			# Install
			cd "Python-$python"
			./configure --enable-optimizations
			ynh_exec_warn_less make -j4
			ynh_exec_warn_less make altinstall

			# Go back to working directory
			cd "$MY_DIR"

			# Clean
			ynh_secure_remove "$tmpdir_py"

			# Set version
			py_app_version="/usr/local/bin/python$python_major"
		fi
	fi
	# Save python version in settings
	ynh_app_setting_set --app=$app --key=python --value="$python"
}

# Install immich
myynh_install_immich() {
	# Thanks to https://github.com/arter97/immich-native

	ynh_use_nodejs

	# Install immich-server
		cd "$tmpdir/server"
		ynh_exec_warn_less "$ynh_npm" ci
		ynh_exec_warn_less "$ynh_npm" run build
		ynh_exec_warn_less "$ynh_npm" prune --omit=dev --omit=optional

		cd "$tmpdir/open-api/typescript-sdk"
		ynh_exec_warn_less "$ynh_npm" ci
		ynh_exec_warn_less "$ynh_npm" run build

		cd "$tmpdir/web"
		ynh_exec_warn_less "$ynh_npm" ci
		ynh_exec_warn_less "$ynh_npm" run build

		mkdir -p "$install_dir/app/"
		cp -a "$tmpdir/server/node_modules" "$install_dir/app/"
		cp -a "$tmpdir/server/dist" "$install_dir/app/"
		cp -a "$tmpdir/server/bin" "$install_dir/app/"
		cp -a "$tmpdir/web/build" "$install_dir/app/www"
		cp -a "$tmpdir/server/resources" "$install_dir/app/"
		cp -a "$tmpdir/server/package.json" "$install_dir/app/"
		cp -a "$tmpdir/server/package-lock.json" "$install_dir/app/"
		cp -a "$tmpdir/server/start-microservices.sh" "$install_dir/app/"
		cp -a "$tmpdir/server/start-server.sh" "$install_dir/app/"
		cp -a "$tmpdir/LICENSE" "$install_dir/app/"
		# Install custom start.sh script
			ynh_add_config --template="immich-server-start.sh" --destination="$install_dir/app/start.sh"
			chmod +x "$install_dir/app/start.sh"
		cd "$install_dir/app/"
		ynh_exec_warn_less "$ynh_npm" cache clean --force

	# Install immich-machine-learning
		cd  "$tmpdir/machine-learning"
		mkdir -p "$install_dir/app/machine-learning"
		$py_app_version -m venv "$install_dir/app/machine-learning/venv"
		(
			# activate the virtual environment
			set +o nounset
			source "$install_dir/app/machine-learning/venv/bin/activate"
			set -o nounset

			# add poetry
			ynh_exec_warn_less "$install_dir/app/machine-learning/venv/bin/pip3" install --upgrade poetry

			# poetry install
			ynh_exec_warn_less "$install_dir/app/machine-learning/venv/bin/poetry" install --no-root --with dev --with cpu
		)
		cp -a "$tmpdir/machine-learning/ann" "$install_dir/app/machine-learning/"
 		cp -a "$tmpdir/machine-learning/app" "$install_dir/app/machine-learning/"
		# Install custom start.sh script
			ynh_add_config --template="immich-machine-learning-start.sh" --destination="$install_dir/app/machine-learning/start.sh"
			chmod +x "$install_dir/app/machine-learning/start.sh"

	# Replace /usr/src
		cd "$install_dir/app"
		grep -Rl "/usr/src" | xargs -n1 sed -i -e "s@/usr/src@$install_dir@g"
		ln -sf "$install_dir/app/resources" "$install_dir/"
		mkdir -p "$install_dir/cache"
		sed -i -e "s@\"/cache\"@\"$install_dir/cache\"@g" "$install_dir/app/machine-learning/app/config.py"

	# Install sharp
		cd "$install_dir/app"
		ynh_exec_warn_less "$ynh_npm" install sharp

	# Use 127.0.0.1 for microservices
		sed -i -e "s@app.listen(port)@app.listen(port, '127.0.0.1')@g" "$install_dir/app/dist/microservices/main.js"

	# Cleanup
		ynh_secure_remove --file="$tmpdir"

	# Install geonames
		wget --output-document="$install_dir/resources/cities500.zip" \
			"https://download.geonames.org/export/dump/cities500.zip" 2>&1
		unzip "$install_dir/resources/cities500.zip" -d "$install_dir/resources/"
		ynh_secure_remove --file="$install_dir/resources/cities500.zip"
		wget --output-document="$install_dir/resources/admin1CodesASCII.txt" \
			"https://download.geonames.org/export/dump/admin1CodesASCII.txt" 2>&1
		wget --output-document="$install_dir/resources/admin2Codes.txt" \
			"https://download.geonames.org/export/dump/admin2Codes.txt" 2>&1
		date --iso-8601=seconds | tr -d "\n" > "$install_dir/resources/geodata-date.txt"

	# Fix permissisons
		chmod 750 "$install_dir"
		chmod -R o-rwx "$install_dir"
		chown -R $app:$app "$install_dir"
}

# Execute a psql command as root user
#
# usage: myynh_execute_psql_as_root --sql=sql [--database=database]
# | arg: -s, --sql=         - the SQL command to execute
# | arg: -d, --database=    - the database to connect to
myynh_execute_psql_as_root() {
	# Declare an array to define the options of this helper.
	local legacy_args=sd
	local -A args_array=([s]=sql= [d]=database=)
	local sql
	local database
	# Manage arguments with getopts
	ynh_handle_getopts_args "$@"
	database="${database:-}"

	if [ -n "$database" ]; then
		database="--dbname=$database"
	fi

	sudo --login --user=postgres PGUSER=postgres PGPASSWORD="$(cat $PSQL_ROOT_PWD_FILE)" \
		psql --cluster="$postgresql_version/main" "$database" --command="$sql"
}

# Install the database
myynh_create_psql_db() {
	myynh_execute_psql_as_root --sql="CREATE DATABASE $app;"
	myynh_execute_psql_as_root --sql="CREATE USER $app WITH ENCRYPTED PASSWORD '$db_pwd';" --database="$app"
	myynh_execute_psql_as_root --sql="GRANT ALL PRIVILEGES ON DATABASE $app TO $app;" --database="$app"
	myynh_execute_psql_as_root --sql="ALTER USER $app WITH SUPERUSER;" --database="$app"
}

# Remove the database
myynh_drop_psql_db() {
	myynh_execute_psql_as_root --sql="REVOKE CONNECT ON DATABASE $app FROM public;"
	myynh_execute_psql_as_root --sql="SELECT pg_terminate_backend (pg_stat_activity.pid) FROM pg_stat_activity \
										WHERE pg_stat_activity.datname = '$app' AND pid <> pg_backend_pid();"
	myynh_execute_psql_as_root --sql="DROP DATABASE $app;"
	myynh_execute_psql_as_root --sql="DROP USER $app;"
}

# Dump the database
myynh_dump_psql_db() {
	local db_port=$(ynh_app_setting_get --app="$app" --key=psql_port)

	sudo --login --user=postgres pg_dump --port="$db_port" --dbname="$app" > db.sql
}

# Restore the database
myynh_restore_psql_db() {
	# https://github.com/immich-app/immich/issues/5630#issuecomment-1866581570
	ynh_replace_string --match_string="SELECT pg_catalog.set_config('search_path', '', false);" \
		--replace_string="SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);" --target_file="db.sql"

	sudo --login --user=postgres PGUSER=postgres PGPASSWORD="$(cat $PSQL_ROOT_PWD_FILE)" \
		psql --cluster="$postgresql_version/main" --dbname="$app" < ./db.sql
}

#=================================================
# EXPERIMENTAL HELPERS
#=================================================

#=================================================
# FUTURE OFFICIAL HELPERS
#=================================================
