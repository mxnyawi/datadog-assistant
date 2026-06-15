-- 🐶 Datadog Assistant , native macOS installer (zero dependencies).
--
-- Uses only built-in macOS dialogs, so it needs no Python, Tk, or pip.
-- Test it now:     osascript installer/install.applescript
-- Build an .app:   ./installer/build_app.sh   (osacompile, built into macOS)

on run
	-- Locate the engine + the app source, whether running as a compiled .app
	-- (files in Contents/Resources) or as a loose script in installer/.
	set mePath to POSIX path of (path to me)
	set resDir to mePath & "/Contents/Resources/"
	try
		do shell script "test -f " & quoted form of (resDir & "do_install.sh")
		set engine to resDir & "do_install.sh"
		set appSrc to resDir & "datadog_assistant.py"
	on error
		set scriptDir to do shell script "dirname " & quoted form of mePath
		set engine to scriptDir & "/do_install.sh"
		set appSrc to scriptDir & "/../datadog_assistant.py"
	end try

	-- Welcome
	display dialog "🐶  Datadog Assistant" & return & return & ¬
		"This sets up the menu bar app. It takes about a minute, and you never need Terminal." ¬
		buttons {"Cancel", "Continue"} default button "Continue" with icon note with title "Datadog Assistant Installer"

	-- 1. Region
	set siteLabels to {"US1   datadoghq.com", "EU   datadoghq.eu", "US3   us3.datadoghq.com", "US5   us5.datadoghq.com", "AP1   ap1.datadoghq.com", "GOV   ddog-gov.com"}
	set siteValues to {"datadoghq.com", "datadoghq.eu", "us3.datadoghq.com", "us5.datadoghq.com", "ap1.datadoghq.com", "ddog-gov.com"}
	set picked to choose from list siteLabels with prompt "Which Datadog site is your org on?" & return & "(check your browser, e.g. app.datadoghq.eu)" default items {item 1 of siteLabels}
	if picked is false then error number -128
	set siteValue to my valueFor(item 1 of picked, siteLabels, siteValues)

	-- 2. Sign in
	set authBtn to button returned of (display dialog "How do you want to sign in to Datadog?" & return & return & ¬
		"Your credentials are stored in the macOS Keychain on this Mac. Nothing is sent to any server." ¬
		buttons {"Cancel", "OAuth", "API + App keys"} default button "API + App keys" with title "Sign in")
	set apiKey to ""
	set appKey to ""
	set clientId to ""
	if authBtn is "API + App keys" then
		set authMode to "keys"
		set apiKey to text returned of (display dialog "Paste your Datadog API key" & return & "(Organization Settings → API Keys)" default answer "" with hidden answer buttons {"Cancel", "Next"} default button "Next" with title "API key")
		set appKey to text returned of (display dialog "Paste your Datadog Application key" & return & "(needs monitors_read / monitors_write / monitors_downtime scopes)" default answer "" with hidden answer buttons {"Cancel", "Next"} default button "Next" with title "Application key")
	else
		set authMode to "oauth"
		set clientId to text returned of (display dialog "Paste your Datadog OAuth Client ID." & return & return & ¬
			"You'll finish the browser login from the menu after install." default answer "" buttons {"Cancel", "Next"} default button "Next" with title "OAuth")
	end if

	-- 3. Optional tag filter
	set tagFilter to text returned of (display dialog "Optional: only show monitors with these tags (space separated)." & return & "Leave blank to show everything." default answer "" buttons {"Skip", "Next"} default button "Next" with title "Filter (optional)")

	-- 4. Install
	display dialog "Ready to install." & return & return & ¬
		"Click Install and wait for the success message (about a minute)." ¬
		buttons {"Cancel", "Install"} default button "Install" with icon note with title "Install"

	set cmd to "export DD_SRC=" & quoted form of appSrc & "; " & ¬
		"export DD_SITE=" & quoted form of siteValue & "; " & ¬
		"export DD_AUTH=" & quoted form of authMode & "; " & ¬
		"export DD_API_KEY=" & quoted form of apiKey & "; " & ¬
		"export DD_APP_KEY=" & quoted form of appKey & "; " & ¬
		"export DD_OAUTH_CLIENT_ID=" & quoted form of clientId & "; " & ¬
		"export DD_TAG_FILTER=" & quoted form of tagFilter & "; " & ¬
		"/bin/bash " & quoted form of engine

	try
		with timeout of 600 seconds
			do shell script cmd
		end timeout
	on error errMsg
		display dialog "⚠️  Install failed" & return & return & errMsg ¬
			buttons {"Close"} default button "Close" with icon stop with title "Datadog Assistant Installer"
		return
	end try

	set doneMsg to "✅  Installed!" & return & return & "Look for the 🐶 in your menu bar. Open it to see your monitors."
	if authMode is "oauth" then
		set doneMsg to doneMsg & return & return & "Finish the OAuth login from the menu: 🐶 → Preferences → Datadog credentials."
	end if
	display dialog doneMsg buttons {"Done"} default button "Done" with icon note with title "Datadog Assistant Installer"
end run

on valueFor(theLabel, labels, values)
	repeat with i from 1 to count of labels
		if item i of labels is theLabel then return item i of values
	end repeat
	return item 1 of values
end valueFor
