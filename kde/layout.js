// macstyle (KDE Plasma 6): a top bar and a dock, run in Plasma by kde/install.sh
// (org.kde.PlasmaShell.evaluateScript). The panels you had are saved first and come back with
// ./uninstall.sh. @LOGO@, @LAUNCHERS@ and @WALLPAPER@ are filled in by the install.

panels().forEach(function (p) { p.remove(); });

// Top bar: the menu of the computer, the menus of the app in front, the tray and the clock
var bar = new Panel("org.kde.panel");
bar.location = "top";
bar.height = 2 * Math.ceil(gridUnit * 0.8);
bar.floating = false;
bar.hiding = "none";

var menu = bar.addWidget("org.kde.plasma.kickoff");
menu.currentConfigGroup = ["General"];
menu.writeConfig("icon", "@LOGO@");
menu.currentConfigGroup = ["Shortcuts"];
menu.writeConfig("global", "Alt+F1");

bar.addWidget("org.kde.plasma.appmenu");
bar.addWidget("org.kde.plasma.panelspacer");
bar.addWidget("org.kde.plasma.systemtray");

var clock = bar.addWidget("org.kde.plasma.digitalclock");
clock.currentConfigGroup = ["Appearance"];
clock.writeConfig("showDate", true);
clock.writeConfig("dateDisplayFormat", "BesideTime");
clock.writeConfig("dateFormat", "custom");
clock.writeConfig("customDateFormat", "ddd d MMM");

// Dock: centred, as wide as its icons, floating, steps aside when a window needs the space
var dock = new Panel("org.kde.panel");
dock.location = "bottom";
dock.height = 2 * Math.ceil(gridUnit * 1.6);
dock.alignment = "center";
dock.lengthMode = "fit";
dock.floating = true;
dock.hiding = "dodgewindows";

var tasks = dock.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", "@LAUNCHERS@");
tasks.writeConfig("showOnlyCurrentDesktop", false);
tasks.writeConfig("showOnlyCurrentActivity", false);
tasks.writeConfig("indicateAudioStreams", true);
tasks.writeConfig("iconSpacing", 1);

dock.addWidget("org.kde.plasma.marginsseparator");
var trash = dock.addWidget("org.kde.plasma.trash");

// The wallpaper: a day and a night picture, switched with the global theme by Plasma itself
desktops().forEach(function (d) {
    d.wallpaperPlugin = "org.kde.image";
    d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    d.writeConfig("Image", "@WALLPAPER@");
});

print("macstyle layout: " + panels().length + " panels");
