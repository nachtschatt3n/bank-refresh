tell application "MoneyMoney"
	if not running then launch
	activate
end tell

delay 2

tell application "System Events"
	tell process "MoneyMoney"
		repeat 30 times
			if frontmost then exit repeat
			delay 0.2
		end repeat

		click menu item "Refresh All Accounts" of menu "File" of menu bar 1
	end tell
end tell
