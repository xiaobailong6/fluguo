package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
)

var nativeUpdateServer = ""

const nativeReleasePrefix = "https://github.com/Xanerix/guoapp/releases/"

var nativeAppVersionPattern = regexp.MustCompile(`^\d+\.\d+\.\d+\+(\d+)$`)

type nativeUpdate struct {
	Available bool   `json:"available"`
	Version   string `json:"version,omitempty"`
	URL       string `json:"url,omitempty"`
}

func nativeAppBuildNumber(version string) (int, bool) {
	match := nativeAppVersionPattern.FindStringSubmatch(version)
	if match == nil {
		return 0, false
	}
	number, err := strconv.Atoi(match[1])
	return number, err == nil
}

func (engine *nativeEngine) checkUpdate(ctx context.Context, version string) (nativeUpdate, error) {
	current, valid := nativeAppBuildNumber(version)
	if !valid {
		return nativeUpdate{}, errors.New("应用版本号无效")
	}
	if nativeUpdateServer == "" {
		return nativeUpdate{}, nil
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, nativeUpdateServer+"/v1/latest", nil)
	if err != nil {
		return nativeUpdate{}, err
	}
	response, err := engine.downloader.client.Do(request)
	if err != nil {
		return nativeUpdate{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nativeUpdate{}, fmt.Errorf("检查更新失败：HTTP %d", response.StatusCode)
	}
	var latest struct {
		Version string `json:"version"`
		URL     string `json:"url"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&latest); err != nil {
		return nativeUpdate{}, err
	}
	number, valid := nativeAppBuildNumber(latest.Version)
	if !valid || number <= current || !strings.HasPrefix(latest.URL, nativeReleasePrefix) {
		return nativeUpdate{}, nil
	}
	return nativeUpdate{Available: true, Version: latest.Version, URL: latest.URL}, nil
}
