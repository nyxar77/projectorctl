import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import Quickshell
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
		? error
		: health === "warning"
			? warning
			: health === "idle" ? muted : success
	readonly property string healthLabel: health === "error"
		? "ERROR"
		: health === "warning"
			? "ATTENTION"
			: health === "idle" ? "WAITING" : "READY"

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

	readonly property color background: token("surface", "#141318")
	readonly property color surfaceLow: token("surfaceContainerLow", "#1d1b20")
	readonly property color surface: token("surfaceContainer", "#211f24")
	readonly property color surfaceHigh: token("surfaceContainerHigh", "#2b292f")
	readonly property color surfaceHighest: token("surfaceContainerHighest", "#36343a")
	readonly property color primary: token("primary", "#c7c4ff")
	readonly property color primaryContainer: token("primaryContainer", "#4b4a77")
	readonly property color secondary: token("secondary", "#c8c5df")
	readonly property color secondaryContainer: token("secondaryContainer", "#45445a")
	readonly property color tertiary: token("tertiary", "#efb6dc")
	readonly property color tertiaryContainer: token("tertiaryContainer", "#684d60")
	readonly property color textStrong: token("onSurface", "#e7e1e8")
	readonly property color muted: token("onSurfaceVariant", "#cac4cf")
	readonly property color outline: token("outline", "#948f99")
	readonly property color outlineVariant: token("outlineVariant", "#49464f")
	readonly property color error: token("error", "#ffb4ab")
	readonly property color errorContainer: token("errorContainer", "#93000a")
	readonly property color success: token("success", "#b5ccba")
	readonly property color warning: token("yellow", "#f0d78c")

	function loadScheme() {
		try {
			const raw = schemeFile.text();
			if (raw && raw.length > 0)
				scheme = JSON.parse(raw);
		} catch (error) {
			scheme = {};
		}
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

	function applyMode(action) {
		if (actionBusy)
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
			errorText = "The display mode could not be applied";
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
			root.statusBusy = false;
			const payload = root.parsePayload(root.statusOutput);
			if (payload)
				root.applyStatus(payload);
			else if (exitCode !== 0)
				root.statusData = {
					ok: false,
					mode: "unavailable",
					modeLabel: "Display service unavailable",
					health: "error",
					message: "Could not read projector status",
					externalAvailable: false,
					outputs: []
				};
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
		interval: 80
		running: true
		repeat: false
		onTriggered: {
			root.loadScheme();
			root.requestStatus();
		}
	}

	Timer {
		interval: 1500
		running: root.panelVisible
		repeat: true
		onTriggered: root.requestStatus()
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
		interval: 260
		repeat: false
		onTriggered: root.closePanel()
	}

	Variants {
		model: Quickshell.screens

		FloatingWindow {
			id: panelWindow
			property var modelData
			screen: modelData

			visible: root.panelVisible
			title: "Projector"
			implicitWidth: 560
			implicitHeight: 520
			minimumSize.width: 520
			minimumSize.height: 500
			maximumSize.width: 600
			maximumSize.height: 560
			color: "transparent"

			Rectangle {
				anchors.fill: parent
				radius: 8
				color: root.background
				border.color: Qt.rgba(root.outline.r, root.outline.g, root.outline.b, 0.34)
				border.width: 1
				focus: true
				Keys.onEscapePressed: root.closePanel()
				Component.onCompleted: forceActiveFocus()

				ColumnLayout {
					anchors.fill: parent
					anchors.margins: 16
					spacing: 12

					RowLayout {
						Layout.fillWidth: true
						Layout.preferredHeight: 34
						spacing: 8

						Text {
							text: "PROJECTOR"
							color: root.muted
							font.pixelSize: 11
							font.weight: Font.DemiBold
							font.letterSpacing: 0
							Layout.fillWidth: true
						}

						ToolButton {
							id: refreshButton
							text: "↻"
							font.pixelSize: 18
							implicitWidth: 34
							implicitHeight: 34
							enabled: !root.actionBusy
							onClicked: root.requestStatus()
							ToolTip.visible: hovered
							ToolTip.text: "Refresh display status"
							background: Rectangle {
								radius: 6
								color: refreshButton.hovered ? root.surfaceHighest : root.surface
								border.color: root.outlineVariant
							}
							contentItem: Text {
								text: refreshButton.text
								color: root.textStrong
								font: refreshButton.font
								horizontalAlignment: Text.AlignHCenter
								verticalAlignment: Text.AlignVCenter
							}
						}

						ToolButton {
							id: closeButton
							text: "×"
							font.pixelSize: 19
							implicitWidth: 34
							implicitHeight: 34
							onClicked: root.closePanel()
							ToolTip.visible: hovered
							ToolTip.text: "Close"
							background: Rectangle {
								radius: 6
								color: closeButton.hovered ? Qt.rgba(root.error.r, root.error.g, root.error.b, 0.14) : root.surface
								border.color: closeButton.hovered ? Qt.rgba(root.error.r, root.error.g, root.error.b, 0.5) : root.outlineVariant
							}
							contentItem: Text {
								text: closeButton.text
								color: closeButton.hovered ? root.error : root.textStrong
								font: closeButton.font
								horizontalAlignment: Text.AlignHCenter
								verticalAlignment: Text.AlignVCenter
							}
						}
					}

					Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: 88
						radius: 6
						color: root.surfaceLow
						border.color: Qt.rgba(root.healthColor.r, root.healthColor.g, root.healthColor.b, 0.45)
						border.width: 1

						Rectangle {
							width: 4
							height: parent.height - 16
							anchors.left: parent.left
							anchors.leftMargin: 8
							anchors.verticalCenter: parent.verticalCenter
							radius: 2
							color: root.healthColor
						}

						ColumnLayout {
							anchors.fill: parent
							anchors.leftMargin: 24
							anchors.rightMargin: 12
							anchors.topMargin: 10
							anchors.bottomMargin: 10
							spacing: 3

							RowLayout {
								Layout.fillWidth: true
								spacing: 8

								Text {
									text: "CURRENT MODE"
									color: root.muted
									font.pixelSize: 10
									font.weight: Font.DemiBold
									font.letterSpacing: 0
									Layout.fillWidth: true
								}

								Rectangle {
									implicitWidth: healthText.implicitWidth + 18
									implicitHeight: 22
									radius: 5
									color: Qt.rgba(root.healthColor.r, root.healthColor.g, root.healthColor.b, 0.12)
									border.color: Qt.rgba(root.healthColor.r, root.healthColor.g, root.healthColor.b, 0.42)

									Text {
										id: healthText
										anchors.centerIn: parent
										text: root.healthLabel
										color: root.healthColor
										font.pixelSize: 9
										font.weight: Font.Bold
										font.letterSpacing: 0
									}
								}
							}

							Text {
								Layout.fillWidth: true
								text: root.currentModeLabel
									color: root.textStrong
								font.pixelSize: 23
								font.weight: Font.DemiBold
								elide: Text.ElideRight
							}

							Text {
								Layout.fillWidth: true
								text: root.statusMessage
								color: root.muted
								font.pixelSize: 11
								elide: Text.ElideRight
							}
						}
					}

					RowLayout {
						Layout.fillWidth: true
						Layout.preferredHeight: 58
						spacing: 8

						OutputTile {
							Layout.fillWidth: true
							outputData: root.internalOutput()
							roleLabel: "Laptop"
							accent: root.secondary
						}

						OutputTile {
							Layout.fillWidth: true
							outputData: root.externalOutput()
							roleLabel: "Projector"
							accent: root.tertiary
						}
					}

					Text {
						text: "CHOOSE A MODE"
						color: root.muted
						font.pixelSize: 10
						font.weight: Font.DemiBold
						font.letterSpacing: 0
					}

					GridLayout {
						Layout.fillWidth: true
						Layout.fillHeight: true
						columns: 2
						columnSpacing: 8
						rowSpacing: 8

						ModeButton {
							Layout.fillWidth: true
							Layout.preferredHeight: 72
							actionId: "duplicate"
							iconGlyph: "⧉"
							label: "Duplicate"
							description: "One shared desktop and pointer"
							accent: root.primary
							accentSurface: root.primaryContainer
							onClicked: root.applyMode(actionId)
						}

						ModeButton {
							Layout.fillWidth: true
							Layout.preferredHeight: 72
							actionId: "external"
							iconGlyph: "▰"
							label: "Projector only"
							description: "Laptop panel wakes if unplugged"
							accent: root.tertiary
							accentSurface: root.tertiaryContainer
							onClicked: root.applyMode(actionId)
						}

						ModeButton {
							Layout.fillWidth: true
							Layout.preferredHeight: 72
							actionId: "builtin"
							iconGlyph: "▣"
							label: "Laptop only"
							description: "Disable external displays"
							accent: root.secondary
							accentSurface: root.secondaryContainer
							externalRequired: false
							onClicked: root.applyMode(actionId)
						}

						ModeButton {
							Layout.fillWidth: true
							Layout.preferredHeight: 72
							actionId: "extend-right"
							iconGlyph: "▣ → ▰"
							label: "Extend right"
							description: "Projector on the right"
							accent: root.primary
							accentSurface: root.primaryContainer
							onClicked: root.applyMode(actionId)
						}

						ModeButton {
							Layout.fillWidth: true
							Layout.preferredHeight: 72
							actionId: "extend-left"
							iconGlyph: "▰ ← ▣"
							label: "Extend left"
							description: "Projector on the left"
							accent: root.tertiary
							accentSurface: root.tertiaryContainer
							onClicked: root.applyMode(actionId)
						}
					}

					Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: 38
						radius: 6
						color: root.errorAction.length > 0
							? Qt.rgba(root.errorContainer.r, root.errorContainer.g, root.errorContainer.b, 0.42)
							: root.surfaceLow
						border.color: root.errorAction.length > 0
							? Qt.rgba(root.error.r, root.error.g, root.error.b, 0.55)
							: root.outlineVariant

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 10
							anchors.rightMargin: 10
							spacing: 8

							Rectangle {
								implicitWidth: 8
								implicitHeight: 8
								radius: 4
								color: root.errorAction.length > 0 ? root.error : root.healthColor
							}

							Text {
								Layout.fillWidth: true
								text: root.errorAction.length > 0
									? root.errorText + (root.errorRecovered ? " - laptop display restored" : "")
									: root.actionBusy ? "Applying display mode..." : root.statusMessage
								color: root.errorAction.length > 0 ? root.error : root.muted
								font.pixelSize: 10
								elide: Text.ElideRight
								verticalAlignment: Text.AlignVCenter
							}
						}
					}
				}
			}
		}
	}

	component OutputTile: Rectangle {
		required property var outputData
		required property string roleLabel
		required property color accent
		readonly property bool detected: outputData !== null && outputData !== undefined
		readonly property bool active: detected && outputData.active === true
		readonly property string outputName: detected ? outputData.name : "Not detected"
		readonly property string outputDetail: !detected
			? "Disconnected"
			: active
				? (outputData.width || 0) + " x " + (outputData.height || 0) + " / " + Math.round(outputData.refreshRate || 0) + " Hz"
				: "Connected / off"

		implicitHeight: 58
		radius: 6
		color: root.surface
		border.color: active
			? Qt.rgba(accent.r, accent.g, accent.b, 0.42)
			: root.outlineVariant
		border.width: 1

		RowLayout {
			anchors.fill: parent
			anchors.margins: 10
			spacing: 9

			Rectangle {
				implicitWidth: 9
				implicitHeight: 36
				radius: 4
				color: active ? accent : root.outline
				opacity: active ? 1 : 0.5
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					Text {
						text: roleLabel
						color: root.muted
						font.pixelSize: 9
						font.weight: Font.DemiBold
						Layout.fillWidth: true
					}

					Text {
						text: active ? "ON" : "OFF"
						color: active ? accent : root.outline
						font.pixelSize: 8
						font.weight: Font.Bold
					}
				}

				Text {
					Layout.fillWidth: true
					text: outputName
					color: root.textStrong
					font.pixelSize: 11
					font.weight: Font.DemiBold
					elide: Text.ElideRight
				}

				Text {
					Layout.fillWidth: true
					text: outputDetail
					color: root.muted
					font.pixelSize: 9
					elide: Text.ElideRight
				}
			}
		}
	}

	component ModeButton: Button {
		id: modeButton

		required property string actionId
		required property string iconGlyph
		required property string label
		required property string description
		required property color accent
		required property color accentSurface
		property bool externalRequired: true
		readonly property bool isPending: root.pendingAction === actionId
		readonly property bool isError: root.errorAction === actionId
		readonly property bool isSelected: root.currentMode === actionId
		readonly property bool unavailable: externalRequired && !root.externalAvailable
		readonly property string displayLabel: isError ? "Error" : isPending ? "Applying..." : label
		readonly property string displayDescription: isError
			? root.errorText
			: isPending
				? "Verifying the new layout"
				: unavailable ? "Connect a projector" : description

		visible: !isSelected || isPending || isError
		enabled: !root.actionBusy && !unavailable
		implicitHeight: 72
		leftPadding: 10
		rightPadding: 10
		topPadding: 8
		bottomPadding: 8
		opacity: unavailable ? 0.52 : 1

		background: Rectangle {
			radius: 6
			color: modeButton.isError
				? Qt.rgba(root.errorContainer.r, root.errorContainer.g, root.errorContainer.b, 0.48)
				: modeButton.isPending
					? Qt.rgba(accentSurface.r, accentSurface.g, accentSurface.b, 0.4)
					: modeButton.down
						? root.surfaceHighest
						: modeButton.hovered ? Qt.rgba(accentSurface.r, accentSurface.g, accentSurface.b, 0.3) : root.surface
			border.color: modeButton.isError
				? root.error
				: modeButton.hovered ? Qt.rgba(accent.r, accent.g, accent.b, 0.62) : root.outlineVariant
			border.width: 1
		}

		contentItem: RowLayout {
			spacing: 10

			Rectangle {
				Layout.preferredWidth: 46
				Layout.preferredHeight: 46
				radius: 6
				color: modeButton.isError
					? Qt.rgba(root.error.r, root.error.g, root.error.b, 0.1)
					: Qt.rgba(accentSurface.r, accentSurface.g, accentSurface.b, 0.34)
				border.color: modeButton.isError
					? Qt.rgba(root.error.r, root.error.g, root.error.b, 0.5)
					: Qt.rgba(accent.r, accent.g, accent.b, 0.32)

				Text {
					anchors.centerIn: parent
					text: modeButton.isError ? "!" : modeButton.iconGlyph
					color: modeButton.isError ? root.error : accent
					font.pixelSize: modeButton.iconGlyph.length > 3 ? 14 : 25
					font.weight: Font.DemiBold
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 3

				Text {
					Layout.fillWidth: true
					text: modeButton.displayLabel
					color: modeButton.isError ? root.error : root.textStrong
					font.pixelSize: 12
					font.weight: Font.DemiBold
					elide: Text.ElideRight
				}

				Text {
					Layout.fillWidth: true
					text: modeButton.displayDescription
					color: modeButton.isError ? root.error : root.muted
					font.pixelSize: 9
					elide: Text.ElideRight
					maximumLineCount: 1
				}
			}
		}
	}
}
