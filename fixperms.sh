#!/bin/bash
# Script to fix permissions of accounts
# Original written by: Vanessa Vasile 5/13/10
# http://thecpaneladmin.com
# Added features by: awalilko@liquidweb.com
# Distributed under BSD-3 license
version=4.6

#ensure we are using bash
[ "$(ps h -p "$$" -o comm)" != "bash" ] && exec bash $0 $*

#set default mode
mode=pubhtml

#set acl storage folder
aclfolder=/tmp/fixperms/

helptext() {
	echo "fixperms version $version
Correct user account permissions to align to control panel standards.
Automatically detects proper server type and adjusts fixes performed.
Back up ACLs before running repairs to $aclfolder.

USAGE
On a cPanel server, usernames are accepted.
cPanel usage:
bash fixperms.sh [-d|-f|-m] [-a|username [username...]]

In a Plesk Linux server, domain names are accepted.
Plesk usage:
bash fixperms.sh [-d|-f|-m] [-a|domain [domain...]]

	-h		display help text
	-a		all users
	-d		docroot mode, affect just site docroots (default)
	-m		mail mode, only affect mail-related files
	-f		full mode, affect entire user homedir
	-u filename.gz	'undo' mode, feed a filepath to restore ACLs
			no username required for undo mode.
"
}

if [ "$#" -lt "1" ]; then #no arguments passed
	helptext
	exit
fi

while getopts :fdmahu: opt; do #parse cli arguments
	case $opt in
	h)
		helptext
		exit
		;;
	a)
		allusers=1
		;;
	f)
		mode=full
		;;
	d)
		mode=pubhtml
		;;
	m)
		mode=mail
		;;
	u)
		undo=1
		file=$OPTARG
		;;
	\?)
		echo "Invalid option: -$OPTARG"
		helptext
		exit
		;;
	:)
		echo "Option -$OPTARG requires an argument!"
		helptext
		exit
		;;
	esac
done

cpaneluserlist() { #compile a userlist for cpanel servers
	if [ $allusers ]; then
		echo "Adding all users to userlist..."
		userlist=$(\ls -A /var/cpanel/users/ | egrep -v "\b(root|bin|nobody|cpanel|halt|system)\b")
	else
		shift $((OPTIND - 1))
		userlist=$(echo $@)
	fi
	if [ "$userlist" = "" ] || [[ $(echo $userlist | egrep "\b(root|bin|nobody|cpanel|halt|system)\b") ]]; then
		echo "Invalid user or no user specified."
		helptext
		exit
	fi
}

pleskuserlist() { #compile a userlist for plesk server
	if [ $allusers ]; then
		echo "Adding all users to userlist..."
		userlist=$(plesk bin subscription -l)
	else
		shift $((OPTIND - 1))
		userlist=$(echo $@)
	fi
	if [ "$userlist" = "" ]; then
		echo "Invalid user or no user specified."
		helptext
		exit
	fi
}

cpanelexecute() { #cpanel fix execution
	for user in $userlist; do
		HOMEDIR=$(egrep ^${user}: /etc/passwd | cut -d: -f6)
		if [ ! -f /var/cpanel/users/$user ]; then
			echo "$user user file missing, likely an invalid user"
		elif [ "$HOMEDIR" == "" ]; then
			echo "Couldn't determine home directory for $user"
		else
			echo "Processing $user..."
			backupacl
			if [ "$mode" = "full" ]; then
				echo "Running full mode..."
				chown -hR $user:$user $HOMEDIR
				chgrp -h nobody $HOMEDIR/public_html $HOMEDIR/.htpasswds
				cpaneldocroot
				cpanelmail

				find $HOMEDIR -type f ! -path "*/mail/*" ! -path "*/.ssh/*" ! -perm 000 -exec chmod 644 {} \;
				find $HOMEDIR -type d ! -path "*/mail/*" ! -path "*/.ssh/*" ! -perm 000 -exec chmod 755 {} \;
				find $HOMEDIR -type d ! -path "*/mail/*" ! -path "*/.ssh/*" -name cgi-bin -exec chmod 755 {} \;
				find $HOMEDIR -type f \( -name "*.pl" -o -name "*.perl" -o -name "*.cgi" \) ! -perm 000 ! -path "*/mail/*" ! -path "*/.ssh/*" -exec chmod 755 {} \;
				chmod 750 $HOMEDIR/public_html
				chmod 711 $HOMEDIR
				for docroot in $(grep \ $user\=\= /etc/userdatadomains | awk -F"==" '{print $5}' | grep $HOMEDIR); do
					chmod 750 $docroot
				done

				if [ -d "$HOMEDIR/.cagefs" ]; then
					chmod 775 $HOMEDIR/.cagefs
					chmod 700 $HOMEDIR/.cagefs/tmp
					chmod 700 $HOMEDIR/.cagefs/var
					chmod 777 $HOMEDIR/.cagefs/cache
					chmod 777 $HOMEDIR/.cagefs/run
				fi

				cpanelhtaccess
			elif [ "$mode" = "mail" ]; then
				echo "Running mail mode..."
				cpanelmail
			else #pubhtml mode
				echo "Running docroot mode..."
				cpaneldocroot

				for docroot in $(grep \ $user\=\= /etc/userdatadomains | awk -F"==" '{print $5}' | grep $HOMEDIR); do
					find $docroot -type f ! -path "*/mail/*" ! -path "*/.ssh/*" ! -perm 000 -exec chmod 644 {} \;
					find $docroot -type d ! -path "*/mail/*" ! -path "*/.ssh/*" ! -perm 000 -exec chmod 755 {} \;
					find $docroot -type d ! -path "*/mail/*" ! -path "*/.ssh/*" -name cgi-bin -exec chmod 755 {} \;
					find $docroot -type f \( -name "*.pl" -o -name "*.perl" -o -name "*.cgi" \) ! -perm 000 -exec chmod 755 {} \;
					chmod 750 $docroot
				done

				cpanelhtaccess
			fi
			echo "$user done!"
		fi
	done
}

cpaneldocroot() {
	for docroot in $(grep \ $user\=\= /etc/userdatadomains | awk -F"==" '{print $5}' | grep $HOMEDIR); do
		chown -hR $user:$user $docroot
		chgrp -h nobody $docroot
	done
}

cpanelmail() {
	chown -hR $user:$user $HOMEDIR/etc $HOMEDIR/mail
	chown -h $user:mail $HOMEDIR/etc $HOMEDIR/etc/*/shadow $HOMEDIR/etc/*/passwd
	find $HOMEDIR/mail/ -type d -exec chmod 751 {} \;
}

cpanelhtaccess() {
	for docroot in $(grep \ $user\=\= /etc/userdatadomains | awk -F"==" '{print $5}' | grep $HOMEDIR); do
		find $docroot -name .htaccess -exec sed -i 's/^\s*php_/#php_/g' {} \;
	done
}

pleskexecute() { #plesk fix execution
	for domain in $userlist; do
		user=$(plesk bin subscription -i $domain | grep FTP\ Login | awk '{print $3}')
		HOMEDIR=$(egrep ^${user}: /etc/passwd | cut -d: -f6)
		if [ "$HOMEDIR" == "" ]; then
			echo "Couldn't determine username or homedir for $domain"
		else
			echo "Processing $domain..."
			backupacl
			if [ "$mode" = "full" ]; then
				echo "Full mode not ready for plesk, running docroot and mail modes..."
				for docroot in $HOMEDIR/httpdocs/; do
					chown -hR $user:psacln $docroot
					chgrp -h psaserv $docroot
					find $docroot -type f ! -perm 000 -exec chmod 644 {} \;
					find $docroot -type d ! -perm 000 -exec chmod 755 {} \;
					chmod 750 $docroot
				done
				chown -R popuser:popuser /var/qmail/mailnames/$domain
			elif [ "$mode" = "mail" ]; then
				echo "Running mail mode..."
				chown -R popuser:popuser /var/qmail/mailnames/$domain
			else
				echo "Running docroot mode..."
				for docroot in $HOMEDIR/httpdocs/; do
					chown -hR $user:psacln $docroot
					chgrp -h psaserv $docroot
					find $docroot -type f ! -perm 000 -exec chmod 644 {} \;
					find $docroot -type d ! -perm 000 -exec chmod 755 {} \;
					chmod 750 $docroot
				done
			fi
			echo "$domain done!"
		fi
	done
}

backupacl() { #store ACLs
	mkdir -p $aclfolder
	echo "Backing up ACL for $user into $aclfolder..."
	local timestamp=$(date +%d%b%Y.%H%M)
	case $servertype in
	cp)
		getfacl -R --absolute-names $HOMEDIR | gzip >$aclfolder/$user.$timestamp.facl.gz
		;;
	plesk)
		getfacl -R --absolute-names $HOMEDIR | gzip >$aclfolder/$domain.$timestamp.facl.gz
		;;
	esac
}

#select undo mode (universal) or correct control panel automatially
if [ $undo ]; then
	# since you are restoring an acl file fixperms made, its assumed acl tools are already installed
	[ ! -f $file ] && echo "This doesn't look like a file... Make sure you pass a full path." && exit
	[[ ! "$file" =~ .*\.gz$ ]] && echo "This doesn't look like a .gz file... Be sure to not unzip it first!" && exit
	echo "Undoing!"
	pushd / &>/dev/null
	gunzip $file
	setfacl --restore ${file%.gz}
	gzip ${file%.gz}
	popd &>/dev/null
	exit
elif [ -f /etc/wwwacct.conf ]; then
	echo "cPanel server detected"
	! rpm --quiet -q acl && echo "Installing acl package..." && yum -y -q install acl
	servertype=cp
	cpaneluserlist $*
	cpanelexecute
elif [ -f /etc/psa/.psa.shadow ]; then
	echo "Plesk server detected"
	! rpm --quiet -q acl && echo "Installing acl package..." && yum -y -q install acl
	servertype=plesk
	pleskuserlist $*
	pleskexecute
else
	echo "Can't detect server type."
	helptext
fi
