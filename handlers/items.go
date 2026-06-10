package handlers

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/ultrazg/xyz/constant"
	"github.com/ultrazg/xyz/utils"
)

type SourceItem struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	URL         string `json:"url"`
	Author      string `json:"author"`
	PublishedAt string `json:"published_at"`
	Cover       string `json:"cover"`
}

type SourceItemsResponse struct {
	Source   string       `json:"source"`
	SourceID string       `json:"source_id"`
	Items    []SourceItem `json:"items"`
}

type xiaoyuzhouAPIResponse struct {
	Data struct {
		Data []xiaoyuzhouEpisode `json:"data"`
	} `json:"data"`
}

type xiaoyuzhouEpisode struct {
	EID     string `json:"eid"`
	PID     string `json:"pid"`
	Title   string `json:"title"`
	Author  string `json:"author"`
	PubDate string `json:"pubDate"`
	Image   struct {
		PicURL string `json:"picUrl"`
	} `json:"image"`
	Podcast struct {
		PID    string `json:"pid"`
		Title  string `json:"title"`
		Author string `json:"author"`
	} `json:"podcast"`
}

// Items returns Xiaoyuzhou episodes using the common datasource protocol.
var Items = func(ctx *gin.Context) {
	token := ctx.Request.Header.Get("x-jike-access-token")
	pid := ctx.Query("pid")
	limit := parseItemsLimit(ctx.Query("limit"))

	var (
		episodes []xiaoyuzhouEpisode
		sourceID string
		err      error
	)

	if pid != "" {
		episodes, err = requestXiaoyuzhouEpisodes(token, pid, limit)
		sourceID = pid
	} else {
		episodes, err = requestXiaoyuzhouInbox(token, limit)
		sourceID = "subscriptions"
	}

	if err != nil {
		log.Println("GET /items", err)
		ctx.JSON(http.StatusBadGateway, gin.H{
			"code": http.StatusBadGateway,
			"msg":  utils.GetMsg(http.StatusBadGateway),
			"data": err.Error(),
		})
		return
	}

	items := make([]SourceItem, 0, len(episodes))
	for _, episode := range episodes {
		if episode.EID == "" || episode.Title == "" {
			continue
		}

		itemSourceID := episode.PID
		if itemSourceID == "" {
			itemSourceID = sourceID
		}

		author := episode.Author
		if author == "" {
			author = episode.Podcast.Title
		}
		if author == "" {
			author = episode.Podcast.Author
		}

		items = append(items, SourceItem{
			ID:          episode.EID,
			Title:       episode.Title,
			URL:         fmt.Sprintf("https://www.xiaoyuzhoufm.com/episode/%s", episode.EID),
			Author:      author,
			PublishedAt: normalizeTime(episode.PubDate),
			Cover:       episode.Image.PicURL,
		})

		if pid == "" && itemSourceID != "" {
			sourceID = itemSourceID
		}
	}

	if pid == "" {
		sourceID = "subscriptions"
	}

	ctx.JSON(http.StatusOK, SourceItemsResponse{
		Source:   "xiaoyuzhou",
		SourceID: sourceID,
		Items:    items,
	})
}

func requestXiaoyuzhouInbox(token string, limit int) ([]xiaoyuzhouEpisode, error) {
	payload := map[string]any{
		"limit": strconv.Itoa(limit),
	}
	return requestXiaoyuzhouEpisodeList("/v1/inbox/list", payload, token)
}

func requestXiaoyuzhouEpisodes(token, pid string, limit int) ([]xiaoyuzhouEpisode, error) {
	payload := map[string]any{
		"limit": strconv.Itoa(limit),
		"pid":   pid,
		"order": "desc",
	}
	return requestXiaoyuzhouEpisodeList("/v1/episode/list", payload, token)
}

func requestXiaoyuzhouEpisodeList(path string, payload map[string]any, token string) ([]xiaoyuzhouEpisode, error) {
	response, code, err := utils.Request(constant.BaseUrl+path, http.MethodPost, payload, xiaoyuzhouHeaders(token))
	if err != nil {
		return nil, fmt.Errorf("%s failed: code=%d err=%w", path, code, err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, fmt.Errorf("read %s response: %w", path, err)
	}

	var parsed xiaoyuzhouAPIResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("parse %s response: %w", path, err)
	}

	return parsed.Data.Data, nil
}

func xiaoyuzhouHeaders(token string) map[string]string {
	isoTime := time.Now().Format("2006-01-02T15:04:05Z07:00")
	return map[string]string{
		"Host":                        "api.xiaoyuzhoufm.com",
		"User-Agent":                  "Xiaoyuzhou/2.57.1 (build:1576; iOS 17.4.1)",
		"Market":                      "AppStore",
		"App-BuildNo":                 "1576",
		"OS":                          "ios",
		"x-jike-access-token":         token,
		"Manufacturer":                "Apple",
		"BundleID":                    "app.podcast.cosmos",
		"Connection":                  "keep-alive",
		"Accept-Language":             "zh-Hans-CN;q=1.0, zh-Hant-TW;q=0.9",
		"Model":                       "iPhone14,2",
		"app-permissions":             "4",
		"Accept":                      "*/*",
		"Content-Type":                "application/json",
		"App-Version":                 "2.57.1",
		"WifiConnected":               "true",
		"OS-Version":                  "17.4.1",
		"x-custom-xiaoyuzhou-app-dev": "",
		"Local-Time":                  isoTime,
		"Timezone":                    "Asia/Shanghai",
	}
}

func parseItemsLimit(value string) int {
	if value == "" {
		return 20
	}

	limit, err := strconv.Atoi(value)
	if err != nil || limit <= 0 {
		return 20
	}
	if limit > 50 {
		return 50
	}
	return limit
}

func normalizeTime(value string) string {
	if value == "" {
		return ""
	}

	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return value
	}

	return parsed.Format(time.RFC3339)
}
