import SwiftUI

/// A view model for the Formbricks WebView.
/// It generates the HTML string with the necessary data to render the survey.
final class FormbricksViewModel: ObservableObject {
    @Published var htmlString: String?
    let surveyId: String

    init(workspaceResponse: WorkspaceResponse, surveyId: String) {
        self.surveyId = surveyId
        if let webviewDataJson = WebViewData(workspaceResponse: workspaceResponse, surveyId: surveyId).getBase64EncodedJson(),
           let surveyScriptUrl = FormbricksWorkspace.surveyScriptUrlString {
            htmlString = htmlTemplate.replacingOccurrences(of: "{{WEBVIEW_DATA}}", with: webviewDataJson)
                .replacingOccurrences(of: "{{SURVEY_SCRIPT_URL}}", with: surveyScriptUrl)
        }
    }
}

private extension FormbricksViewModel {
    /// The HTML template to render the Formbricks WebView.
    var htmlTemplate: String {
        return """
        <!doctype html>
        <html>
            <meta name="viewport" content="initial-scale=1.0, maximum-scale=1.0">

            <head>
                <title>Formbricks WebView Survey</title>
            </head>

            <body style="overflow: hidden; height: 100vh; margin: 0; background: transparent;">
                <div id="formbricks-react-native" style="width: 100%; height: 100%;"></div>
            </body>

            <script type="text/javascript">
                // Payload is base64-encoded UTF-8 JSON (see getBase64EncodedJson) so survey-authored
                // content cannot break out of the string literal and inject script.
                const base64Payload = "{{WEBVIEW_DATA}}";
                const payloadBytes = Uint8Array.from(atob(base64Payload), function (c) { return c.charCodeAt(0); });
                const json = new TextDecoder("utf-8").decode(payloadBytes);
                let surveyProps = '';

                function onClose() {
                    window.webkit.messageHandlers.jsMessage.postMessage(JSON.stringify({ event: "onClose" }));
                };

                function onDisplayCreated() {
                    window.webkit.messageHandlers.jsMessage.postMessage(JSON.stringify({ event: "onDisplayCreated" }));
                };

                function onResponseCreated() {
                    window.webkit.messageHandlers.jsMessage.postMessage(JSON.stringify({ event: "onResponseCreated" }));
                };

                function onOpenExternalURL(url) {
                    window.webkit.messageHandlers.jsMessage.postMessage(JSON.stringify({ event: "onOpenExternalURL", onOpenExternalURLParams: { url: url } }));
                };

                let setResponseFinished = null;
                function getSetIsResponseSendingFinished(callback) {
                    setResponseFinished = callback;
                }

                function loadSurvey() {
                    const options = JSON.parse(json);
                    surveyProps = {
                        ...options,
                        getSetIsResponseSendingFinished,
                        onDisplayCreated,
                        onResponseCreated,
                        onClose,
                        onOpenExternalURL,
                    };
                    window.formbricksSurveys.renderSurvey(surveyProps);
                }

                const script = document.createElement("script");
                script.src = "{{SURVEY_SCRIPT_URL}}";
                script.async = true;
                script.onload = () => loadSurvey();
                script.onerror = (error) => {
                    window.webkit.messageHandlers.jsMessage.postMessage(JSON.stringify({ event: "onSurveyLibraryLoadError" }));
                    console.error("Failed to load Formbricks Surveys library:", error);
                };
                document.head.appendChild(script);
            </script>
        </html>
        """
    }

}

// MARK: - Helper class -
private class WebViewData {
    var data: [String: Any] = [:]

    init(workspaceResponse: WorkspaceResponse, surveyId: String) {
        let matchedSurvey = workspaceResponse.data.data.surveys?.first(where: {$0.id == surveyId})
        let settings = workspaceResponse.data.data.settings

        data["survey"] = workspaceResponse.getSurveyJson(forSurveyId: surveyId)
        data["appUrl"] = Formbricks.appUrl
        data["workspaceId"] = Formbricks.workspaceId
        // Keep `environmentId` in the payload for backward compatibility with older
        // survey-script versions that still read it.
        data["environmentId"] = Formbricks.workspaceId
        data["contactId"] = Formbricks.userManager?.contactId
        data["isWebEnvironment"] = false
        data["isBrandingEnabled"] = settings.inAppSurveyBranding ?? true

        if let placementEnum = matchedSurvey?.projectOverwrites?.placement {
            data["placement"] = placementEnum.rawValue
        } else {
            data["placement"] = settings.placement
        }

        data["clickOutside"] = matchedSurvey?.projectOverwrites?.clickOutsideClose ?? settings.clickOutsideClose ?? false
        data["overlay"] = (matchedSurvey?.projectOverwrites?.overlay ?? settings.overlay ?? .none).rawValue

        let isMultiLangSurvey = (matchedSurvey?.languages?.count ?? 0) > 1

        if isMultiLangSurvey {
            data["languageCode"] = Formbricks.language
        } else {
            data["languageCode"] = "default"
        }

        let hasCustomStyling = matchedSurvey?.styling != nil
        let enabled = settings.styling?.allowStyleOverwrite ?? false

        data["styling"] = hasCustomStyling && enabled ? workspaceResponse.getSurveyStylingJson(forSurveyId: surveyId): workspaceResponse.getSettingsStylingJson()
    }

    /// Returns the survey payload as base64-encoded UTF-8 JSON.
    /// The value is injected into the HTML template and decoded in JS. Base64 output contains no
    /// backticks, `${`, or `</script>` sequences, so survey-authored content cannot break out of the
    /// string literal and inject script (unlike embedding raw JSON directly).
    func getBase64EncodedJson() -> String? {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
            return jsonData.base64EncodedString()
        } catch {
            Formbricks.logger?.error(error.message)
            return nil
        }
    }

}
