# Copia o menu de boot e acrescenta entradas iguais a primeira: instalar ("autoinstall"), instalar com
# video basico ("nomodeset") e diagnostico ("rodiag": relatorio sem instalar, kernel verboso com
# earlyprintk). Tira o "quiet" de todas: em placas antigas a tela preta sem mensagens nao deixa saber
# se travou. No GRUB, "gfxpayload=keep" entrega ao kernel o framebuffer que o GRUB ja usa (sem isso,
# firmware UEFI antigo fica sem console ate o driver de video).
# uso: awk -f dup-entry.awk -v kind=grub|syslinux arquivo.cfg
# initramfs_async=0 em todas: na H61 (UEFI de 2011) a descompactacao assincrona do initramfs trava o boot
function noquiet(l) { gsub(/[ \t]quiet([ \t]|$)/, " ", l); return l " initramfs_async=0" }
function dup(title, label, args,   i, l) {
	print ""
	for (i = s; i <= e; i++) {
		l = L[i]
		if (i == s && kind == "grub") sub(/menuentry[ \t]+("[^"]*"|'[^']*'|[^ \t{]+)/, "menuentry \"" title "\"", l)
		if (i == s && kind == "syslinux") l = "LABEL " label
		if (kind == "syslinux" && toupper(l) ~ /^[ \t]*MENU[ \t]+LABEL/) l = "MENU LABEL " title
		if (kind == "grub" && l ~ /^[ \t]*linux(efi)?[ \t]/) l = l " " args
		if (kind == "syslinux" && toupper(l) ~ /^[ \t]*APPEND[ \t]/) l = l " " args
		print l
	}
}
{ L[++n] = $0 }
END {
	for (i = 1; i <= n; i++) {                 # menu espera 10 s (o original espera 1 s)
		if (kind == "grub" && L[i] ~ /^[ \t]*linux(efi)?[ \t]/) L[i] = noquiet(L[i])
		if (kind == "syslinux" && toupper(L[i]) ~ /^[ \t]*APPEND[ \t]/) L[i] = noquiet(L[i])
		if (kind == "grub" && L[i] ~ /^[ \t]*set[ \t]+timeout=/) L[i] = "set timeout=10\nset gfxpayload=keep"
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
	dup("Alpine RO - instalar automaticamente (APAGA o disco interno)", "roinstall", "autoinstall")
	dup("Alpine RO - instalar, video basico (se a tela ficar preta)", "rosafe", "autoinstall nomodeset")
	# earlyprintk escreve antes de qualquer driver de video (efi no GRUB/UEFI, vga no syslinux/BIOS);
	# initcall_debug mostra cada etapa do kernel (a ultima linha na tela diz onde parou)
	dup("Alpine RO - diagnostico (nao instala nada)", "rodiag", "rodiag nomodeset ignore_loglevel earlyprintk=" (kind == "grub" ? "efi" : "vga") ",keep initcall_debug")
	if (kind == "syslinux") {                  # o ISO oficial nao tem menu.c32: o prompt "boot:" nao lista nada
		split(L[s], a, /[ \t]+/)
		print ""
		print "SAY"
		print "SAY Enter ou aguarde 10 s: " a[2] " (Alpine live)"
		print "SAY Digite roinstall + Enter: instalar o Alpine RO (APAGA o disco interno)"
		print "SAY Digite rosafe + Enter: o mesmo, com video basico (se a tela ficar preta)"
		print "SAY Digite rodiag + Enter: diagnostico da maquina (nao instala nada)"
	}
}
