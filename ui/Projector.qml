pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

Scope {
	id: root

	property string homeDir: StandardPaths.writableLocation(StandardPaths.HomeLocation)
	property bool panelVisible: true
	property var scheme: ({})
	property var statusData: ({
		ok: false,
		mode: "unavailable",
		modeLabel: "Checking displays",
		health: "idle",
		message: "Reading the current layout",
		externalAvailable: false,
		outputs: []
	})
	property bool statusBusy: false
	property bool actionBusy: false
	property string pendingAction: ""
	property string errorAction: ""
	property string errorText: ""
	property bool errorRecovered: false
	property string statusOutput: ""
	property int statusExitCode: 0
	property string actionOutput: ""
	property string actionStderr: ""
	property int actionExitCode: 0

	readonly property string currentMode: statusData.mode || "unknown"
	readonly property string currentModeLabel: statusData.modeLabel || "Unknown layout"
	readonly property string health: statusData.health || "idle"
	readonly property string statusMessage: statusData.message || ""
	readonly property bool externalAvailable: statusData.externalAvailable === true
	readonly property var outputs: statusData.outputs || []
	readonly property color healthColor: health === "error"
		? danger
		: health === "warning"
			? warning
			: health === "idle" ? dim : good
	readonly property var focusedScreen: {
		const monitor = Hyprland.focusedMonitor;
		const wanted = monitor ? monitor.name : "";
		for (let index = 0; index < Quickshell.screens.length; index++) {
			if (Quickshell.screens[index].name === wanted)
				return Quickshell.screens[index];
		}
		return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
	}

	function colorValue(value, fallback) {
		if (value === undefined || value === null)
			return fallback;
		if (typeof value === "string") {
			const clean = value.trim();
			if (clean.length === 0)
				return fallback;
			if (clean[0] === "#" || clean.indexOf("rgb") === 0)
				return clean;
			return "#" + clean;
		}
		if (value.hex)
			return colorValue(value.hex, fallback);
		return fallback;
	}

	function token(name, fallback) {
		if (scheme && scheme.colours && scheme.colours[name] !== undefined)
			return colorValue(scheme.colours[name], fallback);
		if (scheme && scheme[name] !== undefined)
			return colorValue(scheme[name], fallback);
		return fallback;
	}

	function faded(value, opacity) {
		return Qt.rgba(value.r, value.g, value.b, opacity);
	}

	readonly property color background: token("surface", "#111113")
	readonly property color surface: token("surfaceContainer", "#1b1b1e")
	readonly property color hover: token("surfaceContainerHigh", "#26262a")
	readonly property color active: token("primary", "#d6d3ff")
	readonly property color laptopAccent: token("secondary", "#c9c5df")
	readonly property color projectorAccent: token("tertiary", "#efb6dc")
	readonly property color text: token("onSurface", "#eeecef")
	readonly property color dim: token("onSurfaceVariant", "#aaa7af")
	readonly property color line: token("outlineVariant", "#45444a")
	readonly property color danger: token("error", "#ffb4ab")
	readonly property color warning: token("yellow", "#e7c66b")
	readonly property color good: token("success", "#9fd3ad")

	function loadScheme() {
		try {
			const raw = schemeFile.text();
			scheme = raw && raw.length > 0 ? JSON.parse(raw) : {};
		} catch (error) {
			scheme = {};
		}
	}

	function modeAccent(mode) {
		if (mode === "builtin")
			return laptopAccent;
		if (mode === "external")
			return projectorAccent;
		return active;
	}

	function parsePayload(raw) {
		try {
			return JSON.parse((raw || "").trim());
		} catch (error) {
			return null;
		}
	}

	function applyStatus(payload) {
		if (payload && payload.mode !== undefined)
			statusData = payload;
	}

	function requestStatus() {
		if (statusBusy || actionBusy)
			return;
		statusBusy = true;
		statusOutput = "";
		statusProcess.exec(["projectorctl", "status"]);
	}

	function finishStatus() {
		statusBusy = false;
		const payload = parsePayload(statusOutput);
		if (payload) {
			applyStatus(payload);
			return;
		}
		if (statusExitCode !== 0) {
			statusData = {
				ok: false,
				mode: "unavailable",
				modeLabel: "Display service unavailable",
				health: "error",
				message: "projectorctl did not return a status",
				externalAvailable: false,
				outputs: []
			};
		}
	}

	function applyMode(action) {
		if (actionBusy || action === currentMode)
			return;
		if (action !== "builtin" && !externalAvailable)
			return;
		actionBusy = true;
		pendingAction = action;
		errorAction = "";
		errorText = "";
		errorRecovered = false;
		actionOutput = "";
		actionStderr = "";
		actionProcess.exec(["projectorctl", "apply", action]);
	}

	function finishAction() {
		const action = pendingAction;
		const payload = parsePayload(actionOutput);
		actionBusy = false;
		pendingAction = "";

		if (actionExitCode === 0 && payload && payload.ok === true && payload.result === "success") {
			applyStatus(payload);
			errorAction = "";
			errorText = "";
			closeTimer.start();
			return;
		}

		errorAction = action;
		errorRecovered = payload && payload.recovered === true;
		if (payload && payload.error)
			errorText = payload.error;
		else if (actionStderr.trim().length > 0)
			errorText = actionStderr.trim();
		else
			errorText = "That layout did not stick";
		refreshAfterError.start();
	}

	function closePanel() {
		panelVisible = false;
		Qt.quit();
	}

	function outputByName(name) {
		if (!name)
			return null;
		for (let index = 0; index < outputs.length; index++) {
			if (outputs[index] && outputs[index].name === name)
				return outputs[index];
		}
		return null;
	}

	function internalOutput() {
		for (let index = 0; index < outputs.length; index++) {
			if (outputs[index] && outputs[index].internal === true)
				return outputs[index];
		}
		return null;
	}

	function externalOutput() {
		const selected = outputByName(statusData.external || "");
		if (selected)
			return selected;
		for (let index = 0; index < outputs.length; index++) {
			if (outputs[index] && outputs[index].internal !== true)
				return outputs[index];
		}
		return null;
	}

	function outputDetail(output) {
		if (!output)
			return "not connected";
		if (output.active !== true)
			return "connected, off";
		return (output.width || 0) + "×" + (output.height || 0)
			+ "  " + Math.round(output.refreshRate || 0) + " Hz";
	}

	function handleKey(event) {
		if (event.key === Qt.Key_Escape) {
			closePanel();
			event.accepted = true;
		} else if (event.key === Qt.Key_R) {
			requestStatus();
			event.accepted = true;
		} else if (event.key === Qt.Key_1) {
			applyMode("builtin");
			event.accepted = true;
		} else if (event.key === Qt.Key_2) {
			applyMode("duplicate");
			event.accepted = true;
		} else if (event.key === Qt.Key_3) {
			applyMode("external");
			event.accepted = true;
		} else if (event.key === Qt.Key_4) {
			applyMode("extend-right");
			event.accepted = true;
		} else if (event.key === Qt.Key_5) {
			applyMode("extend-left");
			event.accepted = true;
		}
	}

	FileView {
		id: schemeFile
		path: root.homeDir + "/.local/state/caelestia/scheme.json"
		preload: true
		watchChanges: true
		printErrors: false
		onLoaded: root.loadScheme()
		onTextChanged: root.loadScheme()
	}

	Process {
		id: statusProcess
		stdout: StdioCollector {
			onStreamFinished: root.statusOutput = text
		}
		stderr: StdioCollector {}
		onExited: function(exitCode) {
			root.statusExitCode = exitCode;
			statusResultDelay.restart();
		}
	}

	Process {
		id: actionProcess
		stdout: StdioCollector {
			onStreamFinished: root.actionOutput = text
		}
		stderr: StdioCollector {
			onStreamFinished: root.actionStderr = text
		}
		onExited: function(exitCode) {
			root.actionExitCode = exitCode;
			actionResultDelay.restart();
		}
	}

	Timer {
		id: startupTimer
		interval: 60
		running: true
		repeat: false
		onTriggered: {
			root.loadScheme();
			root.requestStatus();
		}
	}

	Timer {
		interval: 1800
		running: root.panelVisible
		repeat: true
		onTriggered: root.requestStatus()
	}

	Timer {
		id: statusResultDelay
		interval: 20
		repeat: false
		onTriggered: root.finishStatus()
	}

	Timer {
		id: actionResultDelay
		interval: 20
		repeat: false
		onTriggered: root.finishAction()
	}

	Timer {
		id: refreshAfterError
		interval: 120
		repeat: false
		onTriggered: root.requestStatus()
	}

	Timer {
		id: closeTimer
		interval: 320
		repeat: false
		onTriggered: root.closePanel()
	}

	FloatingWindow {
		id: panelWindow
		screen: root.focusedScreen
		visible: root.panelVisible && root.focusedScreen !== null
		title: "projector"
		implicitWidth: 460
		implicitHeight: 566
		minimumSize.width: 430
		minimumSize.height: 540
		maximumSize.width: 500
		maximumSize.height: 620
		color: "transparent"

		Rectangle {
			anchors.fill: parent
			radius: 11
			color: root.background
			border.color: root.faded(root.line, 0.8)
			border.width: 1
			focus: true
			Keys.onPressed: event => root.handleKey(event)
			Component.onCompleted: forceActiveFocus()

			ColumnLayout {
				anchors.fill: parent
				anchors.margins: 20
				spacing: 0

				RowLayout {
					Layout.fillWidth: true
					Layout.preferredHeight: 48
					spacing: 10

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 1

						Text {
							text: "projector"
							color: root.text
							font.pixelSize: 21
							font.weight: Font.DemiBold
						}

						Text {
							Layout.fillWidth: true
							text: root.externalOutput()
								? root.externalOutput().name + " · " + root.externalOutput().description
								: "no external display connected"
							color: root.dim
							font.pixelSize: 10
							elide: Text.ElideRight
						}
					}

					QuietButton {
						glyph: "↻"
						accessibleName: "Refresh status"
						enabled: !root.actionBusy
						onClicked: root.requestStatus()
					}

					QuietButton {
						glyph: "×"
						accessibleName: "Close"
						onClicked: root.closePanel()
					}
				}

				RowLayout {
					Layout.fillWidth: true
					Layout.preferredHeight: 34
					spacing: 8

					Rectangle {
						implicitWidth: 8
						implicitHeight: 8
						radius: 4
						color: root.healthColor
					}

					Text {
						text: root.currentModeLabel
						color: root.text
						font.pixelSize: 12
						font.weight: Font.DemiBold
					}

					Text {
						text: "—"
						color: root.line
						font.pixelSize: 11
					}

					Text {
						Layout.fillWidth: true
						text: root.statusBusy ? "checking…" : root.statusMessage
						color: root.dim
						font.pixelSize: 10
						elide: Text.ElideRight
					}
				}

				DisplayPair {
					Layout.fillWidth: true
					Layout.preferredHeight: 72
					laptop: root.internalOutput()
					projector: root.externalOutput()
				}

				Text {
					Layout.topMargin: 16
					Layout.bottomMargin: 8
					text: "Where should this desktop go?"
					color: root.text
					font.pixelSize: 12
					font.weight: Font.DemiBold
				}

				Rectangle {
					Layout.fillWidth: true
					Layout.preferredHeight: 286
					radius: 8
					color: root.surface
					border.color: root.line
					border.width: 1

					ColumnLayout {
						anchors.fill: parent
						anchors.margins: 1
						spacing: 0

						ModeRow {
							Layout.fillWidth: true
							Layout.fillHeight: true
							actionId: "builtin"
							shortcutText: "1"
							titleText: "Laptop only"
							detailText: "Turn every external display off"
							externalRequired: false
							onClicked: root.applyMode(actionId)
						}

						Hairline { Layout.fillWidth: true }

						ModeRow {
							Layout.fillWidth: true
							Layout.fillHeight: true
							actionId: "duplicate"
							shortcutText: "2"
							titleText: "Mirror"
							detailText: "Show the same desktop on both"
							onClicked: root.applyMode(actionId)
						}

						Hairline { Layout.fillWidth: true }

						ModeRow {
							Layout.fillWidth: true
							Layout.fillHeight: true
							actionId: "external"
							shortcutText: "3"
							titleText: "Projector only"
							detailText: "Laptop wakes if the cable comes out"
							onClicked: root.applyMode(actionId)
						}

						Hairline { Layout.fillWidth: true }

						ModeRow {
							Layout.fillWidth: true
							Layout.fillHeight: true
							actionId: "extend-right"
							shortcutText: "4"
							titleText: "Extend right"
							detailText: "Put the projector to the right"
							onClicked: root.applyMode(actionId)
						}

						Hairline { Layout.fillWidth: true }

						ModeRow {
							Layout.fillWidth: true
							Layout.fillHeight: true
							actionId: "extend-left"
							shortcutText: "5"
							titleText: "Extend left"
							detailText: "Put the projector to the left"
							onClicked: root.applyMode(actionId)
						}
					}
				}

				RowLayout {
					Layout.fillWidth: true
					Layout.fillHeight: true
					Layout.minimumHeight: 34
					spacing: 8

					Text {
						Layout.fillWidth: true
						text: root.errorAction.length > 0
							? root.errorText + (root.errorRecovered ? " · laptop restored" : "")
							: root.actionBusy ? "changing layout…" : "Esc closes · R checks again"
						color: root.errorAction.length > 0 ? root.danger : root.dim
						font.pixelSize: 10
						elide: Text.ElideRight
					}
				}
			}
		}
	}

	component Hairline: Rectangle {
		implicitHeight: 1
		color: root.line
		opacity: 0.65
	}

	component QuietButton: Button {
		id: quietButton

		required property string glyph
		required property string accessibleName

		text: glyph
		Accessible.name: accessibleName
		implicitWidth: 32
		implicitHeight: 32
		padding: 0

		background: Rectangle {
			radius: 6
			color: quietButton.down
				? root.faded(root.text, 0.12)
				: quietButton.hovered ? root.hover : "transparent"
		}

		contentItem: Text {
			text: quietButton.glyph
			color: quietButton.enabled ? root.dim : root.faded(root.dim, 0.4)
			font.pixelSize: quietButton.glyph === "×" ? 20 : 17
			horizontalAlignment: Text.AlignHCenter
			verticalAlignment: Text.AlignVCenter
		}
	}

	component DisplayPair: Rectangle {
		id: pair

		required property var laptop
		required property var projector
		readonly property bool projectorFirst: root.currentMode === "extend-left"

		radius: 8
		color: root.faded(root.surface, 0.62)
		border.color: root.line
		border.width: 1

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 14
			anchors.rightMargin: 14
			spacing: 12
			layoutDirection: pair.projectorFirst ? Qt.RightToLeft : Qt.LeftToRight

			MonitorLabel {
				Layout.fillWidth: true
				outputData: pair.laptop
				roleName: "laptop"
				alignRight: pair.projectorFirst
				accentColor: root.laptopAccent
			}

			Text {
				text: root.currentMode === "duplicate"
					? "="
					: root.currentMode === "extend-left"
						? "←"
						: root.currentMode === "extend-right" ? "→" : "·"
				color: root.externalAvailable ? root.active : root.line
				font.pixelSize: 18
				font.weight: Font.DemiBold
			}

			MonitorLabel {
				Layout.fillWidth: true
				outputData: pair.projector
				roleName: "projector"
				alignRight: !pair.projectorFirst
				accentColor: root.projectorAccent
			}
		}
	}

	component MonitorLabel: RowLayout {
		id: monitorLabel

		required property var outputData
		required property string roleName
		required property color accentColor
		property bool alignRight: false
		readonly property bool isActive: outputData && outputData.active === true

		layoutDirection: alignRight ? Qt.RightToLeft : Qt.LeftToRight
		spacing: 9

		Item {
			Layout.preferredWidth: 30
			Layout.preferredHeight: 28

			Rectangle {
				width: 28
				height: 18
				anchors.top: parent.top
				anchors.horizontalCenter: parent.horizontalCenter
				radius: 2
				color: "transparent"
				border.width: 2
				border.color: monitorLabel.isActive ? monitorLabel.accentColor : root.line
			}

			Rectangle {
				width: 2
				height: 5
				anchors.top: parent.top
				anchors.topMargin: 18
				anchors.horizontalCenter: parent.horizontalCenter
				color: monitorLabel.isActive ? monitorLabel.accentColor : root.line
			}

			Rectangle {
				width: 14
				height: 2
				anchors.bottom: parent.bottom
				anchors.horizontalCenter: parent.horizontalCenter
				radius: 1
				color: monitorLabel.isActive ? monitorLabel.accentColor : root.line
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			Text {
				Layout.fillWidth: true
				text: monitorLabel.outputData ? monitorLabel.outputData.name : monitorLabel.roleName
				color: monitorLabel.outputData ? root.text : root.dim
				font.pixelSize: 11
				font.weight: Font.DemiBold
				horizontalAlignment: monitorLabel.alignRight ? Text.AlignRight : Text.AlignLeft
				elide: Text.ElideRight
			}

			Text {
				Layout.fillWidth: true
				text: root.outputDetail(monitorLabel.outputData)
				color: root.dim
				font.pixelSize: 9
				horizontalAlignment: monitorLabel.alignRight ? Text.AlignRight : Text.AlignLeft
				elide: Text.ElideRight
			}
		}
	}

	component ModeRow: Button {
		id: modeRow

		required property string actionId
		required property string shortcutText
		required property string titleText
		required property string detailText
		property bool externalRequired: true
		readonly property bool isCurrent: root.currentMode === actionId
		readonly property bool isPending: root.pendingAction === actionId
		readonly property bool isError: root.errorAction === actionId
		readonly property bool unavailable: externalRequired && !root.externalAvailable
		readonly property color rowAccent: root.modeAccent(actionId)

		text: titleText
		Accessible.description: detailText
		enabled: !root.actionBusy && !unavailable && !isCurrent
		opacity: unavailable ? 0.42 : 1
		leftPadding: 12
		rightPadding: 12
		topPadding: 5
		bottomPadding: 5

		background: Rectangle {
			radius: 7
			color: modeRow.isError
				? root.faded(root.danger, 0.1)
				: modeRow.isCurrent
					? root.faded(modeRow.rowAccent, 0.1)
					: modeRow.down
						? root.faded(root.text, 0.1)
						: modeRow.hovered ? root.hover : "transparent"

			Rectangle {
				visible: modeRow.isCurrent || modeRow.isPending
				width: 3
				height: 24
				anchors.left: parent.left
				anchors.leftMargin: 4
				anchors.verticalCenter: parent.verticalCenter
				radius: 2
				color: modeRow.rowAccent
			}
		}

		contentItem: RowLayout {
			spacing: 11

			DisplaySketch {
				Layout.preferredWidth: 62
				Layout.preferredHeight: 32
				modeId: modeRow.actionId
				lit: !modeRow.unavailable
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				Text {
					Layout.fillWidth: true
					text: modeRow.isPending ? "Changing…" : modeRow.titleText
					color: modeRow.isError ? root.danger : root.text
					font.pixelSize: 11
					font.weight: Font.DemiBold
					elide: Text.ElideRight
				}

				Text {
					Layout.fillWidth: true
					text: modeRow.unavailable ? "Connect an external display" : modeRow.detailText
					color: modeRow.isError ? root.danger : root.dim
					font.pixelSize: 9
					elide: Text.ElideRight
				}
			}

			Text {
				text: modeRow.isCurrent ? "current" : modeRow.shortcutText
				color: modeRow.isCurrent ? modeRow.rowAccent : root.dim
				font.pixelSize: 9
				font.weight: modeRow.isCurrent ? Font.DemiBold : Font.Normal
			}
		}
	}

	component DisplaySketch: Item {
		id: sketch

		required property string modeId
		required property bool lit
		readonly property bool projectorFirst: modeId === "extend-left"
		readonly property bool laptopOn: modeId !== "external"
		readonly property bool projectorOn: modeId !== "builtin" && lit
		readonly property int laptopX: projectorFirst ? 40 : 1
		readonly property int projectorX: projectorFirst ? 1 : 40

		Rectangle {
			x: sketch.laptopX
			y: 5
			width: 20
			height: 14
			radius: 2
			color: "transparent"
			border.width: 2
			border.color: sketch.laptopOn ? root.laptopAccent : root.line
			opacity: sketch.laptopOn ? 1 : 0.5
		}

		Rectangle {
			x: sketch.laptopX - 2
			y: 21
			width: 24
			height: 2
			radius: 1
			color: sketch.laptopOn ? root.laptopAccent : root.line
			opacity: sketch.laptopOn ? 1 : 0.5
		}

		Rectangle {
			x: sketch.projectorX
			y: 4
			width: 21
			height: 16
			radius: 2
			color: "transparent"
			border.width: 2
			border.color: sketch.projectorOn ? root.projectorAccent : root.line
			opacity: sketch.projectorOn ? 1 : 0.5
		}

		Rectangle {
			x: sketch.projectorX + 9
			y: 20
			width: 2
			height: 4
			color: sketch.projectorOn ? root.projectorAccent : root.line
			opacity: sketch.projectorOn ? 1 : 0.5
		}

		Rectangle {
			x: sketch.projectorX + 4
			y: 24
			width: 12
			height: 2
			radius: 1
			color: sketch.projectorOn ? root.projectorAccent : root.line
			opacity: sketch.projectorOn ? 1 : 0.5
		}

		Text {
			visible: sketch.modeId === "duplicate" || sketch.modeId.indexOf("extend-") === 0
			x: 25
			y: 4
			width: 12
			height: 20
			text: sketch.modeId === "duplicate" ? "=" : "—"
			color: sketch.lit ? root.active : root.line
			font.pixelSize: sketch.modeId === "duplicate" ? 12 : 10
			horizontalAlignment: Text.AlignHCenter
			verticalAlignment: Text.AlignVCenter
		}
	}
}
