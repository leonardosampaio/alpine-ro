# Copia o menu de boot e acrescenta uma entrada igual a primeira, com "autoinstall" no cmdline.
# uso: awk -f dup-entry.awk -v kind=grub|syslinux arquivo.cfg
{ L[++n] = $0 }
END {
	for (i = 1; i <= n; i++) {                 # menu espera 10 s (o original espera 1 s)
		if (kind == "grub" && L[i] ~ /^[ \t]*set[ \t]+timeout=/) L[i] = "set timeout=10"
		if (kind == "syslinux" && toupper(L[i]) ~ /^[ \t]*TIMEOUT[ \t]/) L[i] = "TIMEOUT 100"
		print L[i]
	}
	s = 0
	for (i = 1; i <= n; i++) {
		if (kind == "grub" && L[i] ~ /^[ \t]*menuentry[ \t]/) { s = i; break }
		if (kind == "syslinux" && toupper(L[i]) ~ /^[ \t]*LABEL[ \t]/) { s = i; break }
	}
	if (!s) { print "# (sem entrada para duplicar)"; exit 0 }
	if (kind == "grub") {
		d = 0
		for (e = s; e <= n; e++) { t = L[e]; d += gsub(/[{]/, "{", t); d -= gsub(/[}]/, "}", t); if (d <= 0 && e > s) break; if (d <= 0 && L[e] ~ /[}]/) break }
	} else {
		for (e = s + 1; e <= n; e++) if (toupper(L[e]) ~ /^[ \t]*LABEL[ \t]/) break
		e--
	}
	print ""
	for (i = s; i <= e; i++) {
		l = L[i]
		if (i == s && kind == "grub") sub(/menuentry[ \t]+("[^"]*"|'[^']*'|[^ \t{]+)/, "menuentry \"Alpine RO - instalar automaticamente (APAGA o disco interno)\"", l)
		if (i == s && kind == "syslinux") l = "LABEL roinstall"
		if (kind == "syslinux" && toupper(l) ~ /^[ \t]*MENU[ \t]+LABEL/) l = "MENU LABEL Alpine RO - instalar automaticamente (APAGA o disco interno)"
		if (kind == "grub" && l ~ /^[ \t]*linux(efi)?[ \t]/) l = l " autoinstall"
		if (kind == "syslinux" && toupper(l) ~ /^[ \t]*APPEND[ \t]/) l = l " autoinstall"
		print l
	}
	if (kind == "syslinux") {                  # o ISO oficial nao tem menu.c32: o prompt "boot:" nao lista nada
		split(L[s], a, /[ \t]+/)
		print ""
		print "SAY"
		print "SAY Enter ou aguarde 10 s: " a[2] " (Alpine live)"
		print "SAY Digite roinstall + Enter: instalar o Alpine RO (APAGA o disco interno)"
	}
}
