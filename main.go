// SHINODRIVE — 멘헤라 NAS 파일 관리 웹앱 (Samba 상위호환)
// 단일 정적 바이너리, 표준 라이브러리만. root=/home/nas 서빙.
package main

import (
	"archive/zip"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web
var webFS embed.FS

var (
	root   = envOr("SHINODRIVE_ROOT", "/home/nas")
	addr   = envOr("SHINODRIVE_ADDR", ":8090")
	cfgDir = envOr("SHINODRIVE_CFG", os.Getenv("HOME")+"/.config/shinodrive")
	secret []byte

	users   = map[string]*User{}
	usersMu sync.Mutex

	shares   = map[string]shareRec{}
	sharesMu sync.Mutex

	cpuPrev [2]uint64
	cpuMu   sync.Mutex
)

// User — 계정. Role: admin(전체+유저관리) / editor(읽기쓰기) / reader(읽기전용).
// Home: root 아래 개인 폴더 (""=root 전체, admin용).
type User struct {
	Name string `json:"-"`
	Pass string `json:"pass"` // sha256 hex
	Role string `json:"role"`
	Home string `json:"home"`
}

func (u *User) canWrite() bool { return u != nil && (u.Role == "admin" || u.Role == "editor") }
func (u *User) isAdmin() bool  { return u != nil && u.Role == "admin" }

type ctxKey int

const userKey ctxKey = 0

func curUser(r *http.Request) *User {
	if u, ok := r.Context().Value(userKey).(*User); ok {
		return u
	}
	return nil
}
func rootFor(r *http.Request) string {
	if u := curUser(r); u != nil && u.Home != "" {
		return filepath.Join(root, u.Home)
	}
	return root
}

type shareRec struct {
	Path    string `json:"path"`
	IsDir   bool   `json:"isDir"`
	Name    string `json:"name"`
	Owner   string `json:"owner"`
	Created int64  `json:"created"`
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	os.MkdirAll(cfgDir, 0700)
	loadSecret()
	loadUsers()
	loadShares()
	if err := os.MkdirAll(root, 0755); err != nil {
		fmt.Fprintln(os.Stderr, "root:", err)
	}
	ensureHomes()

	mux := http.NewServeMux()
	sub, _ := fs.Sub(webFS, "web")
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.FS(sub))))
	mux.HandleFunc("/", serveIndex(sub))
	mux.HandleFunc("/api/login", hLogin)
	mux.HandleFunc("/api/logout", hLogout)
	mux.HandleFunc("/api/me", auth(hMe))
	mux.HandleFunc("/api/list", auth(hList))
	mux.HandleFunc("/api/mkdir", authW(hMkdir))
	mux.HandleFunc("/api/delete", authW(hDelete))
	mux.HandleFunc("/api/rename", authW(hRename))
	mux.HandleFunc("/api/upload", authW(hUpload))
	mux.HandleFunc("/api/usage", auth(hUsage))
	mux.HandleFunc("/dl", auth(hDownload))
	mux.HandleFunc("/raw", auth(hRaw))
	mux.HandleFunc("/stream", auth(hStream))
	mux.HandleFunc("/api/sys", auth(hSys))
	mux.HandleFunc("/api/share", auth(hShare))
	mux.HandleFunc("/api/shares", auth(hShares))
	mux.HandleFunc("/api/unshare", auth(hUnshare))
	mux.HandleFunc("/s/", hSharePage(sub)) // 공개 공유 페이지
	mux.HandleFunc("/sd/", hShareData)     // 공개 공유 데이터 API
	mux.HandleFunc("/thumb", auth(hThumb))
	mux.HandleFunc("/api/search", auth(hSearch))
	mux.HandleFunc("/api/zip", auth(hZip))
	mux.HandleFunc("/api/users", authA(hUsers))       // 관리자: 목록/추가
	mux.HandleFunc("/api/users/del", authA(hUserDel)) // 관리자: 삭제
	mux.HandleFunc("/api/passwd", auth(hPasswd))      // 본인 비번 변경

	fmt.Println("SHINODRIVE on", addr, "root", root)
	srv := &http.Server{Addr: addr, Handler: logmw(mux), ReadHeaderTimeout: 15 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func logmw(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { h.ServeHTTP(w, r) })
}

// ── secret & password ──
func loadSecret() {
	p := filepath.Join(cfgDir, "secret")
	if b, err := os.ReadFile(p); err == nil && len(b) >= 32 {
		secret = b
		return
	}
	secret = make([]byte, 32)
	rand.Read(secret)
	os.WriteFile(p, secret, 0600)
}

func hashPw(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

// users.json 로드. 없으면 password.txt(옛 단일비번)에서 admin 계정으로 마이그레이션.
func loadUsers() {
	usersMu.Lock()
	defer usersMu.Unlock()
	p := filepath.Join(cfgDir, "users.json")
	if b, err := os.ReadFile(p); err == nil {
		m := map[string]*User{}
		if json.Unmarshal(b, &m) == nil {
			for name, u := range m {
				u.Name = name
			}
			users = m
			return
		}
	}
	// 마이그레이션: password.txt → admin
	pw := "menhera"
	if b, err := os.ReadFile(filepath.Join(cfgDir, "password.txt")); err == nil {
		pw = strings.TrimSpace(string(b))
	}
	users = map[string]*User{"admin": {Name: "admin", Pass: hashPw(pw), Role: "admin", Home: ""}}
	saveUsersLocked()
}
func saveUsers() { usersMu.Lock(); saveUsersLocked(); usersMu.Unlock() }
func saveUsersLocked() {
	b, _ := json.MarshalIndent(users, "", "  ")
	os.WriteFile(filepath.Join(cfgDir, "users.json"), b, 0600)
}
func ensureHomes() {
	usersMu.Lock()
	defer usersMu.Unlock()
	for _, u := range users {
		if u.Home != "" {
			os.MkdirAll(filepath.Join(root, u.Home), 0755)
		}
	}
}
func getUser(name string) *User {
	usersMu.Lock()
	defer usersMu.Unlock()
	return users[name]
}

// ── auth token: <user>.<exp>.<hmac(user|exp)> ──
func makeToken(user string) string {
	exp := time.Now().Add(30 * 24 * time.Hour).Unix()
	msg := user + "|" + strconv.FormatInt(exp, 10)
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(msg))
	return user + "." + strconv.FormatInt(exp, 10) + "." + hex.EncodeToString(mac.Sum(nil))
}

// tokenUser: 토큰 검증 후 해당 User 반환 (nil이면 무효)
func tokenUser(t string) *User {
	parts := strings.Split(t, ".")
	if len(parts) != 3 {
		return nil
	}
	user, expS, sig := parts[0], parts[1], parts[2]
	exp, err := strconv.ParseInt(expS, 10, 64)
	if err != nil || time.Now().Unix() > exp {
		return nil
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(user + "|" + expS))
	want := hex.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(want), []byte(sig)) {
		return nil
	}
	return getUser(user)
}

func auth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u := tokenUser(reqToken(r))
		if u == nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		h(w, r.WithContext(context.WithValue(r.Context(), userKey, u)))
	}
}
func authW(h http.HandlerFunc) http.HandlerFunc { // 쓰기 권한 필요
	return auth(func(w http.ResponseWriter, r *http.Request) {
		if !curUser(r).canWrite() {
			http.Error(w, "읽기 전용 계정이에요 ♡", http.StatusForbidden)
			return
		}
		h(w, r)
	})
}
func authA(h http.HandlerFunc) http.HandlerFunc { // 관리자 필요
	return auth(func(w http.ResponseWriter, r *http.Request) {
		if !curUser(r).isAdmin() {
			http.Error(w, "관리자만 가능해요", http.StatusForbidden)
			return
		}
		h(w, r)
	})
}

// 토큰 소스: 쿠키(웹) / Authorization Bearer(앱) / ?t= 쿼리(미디어 로딩용)
func reqToken(r *http.Request) string {
	if c, err := r.Cookie("sd_auth"); err == nil && c.Value != "" {
		return c.Value
	}
	if a := r.Header.Get("Authorization"); strings.HasPrefix(a, "Bearer ") {
		return strings.TrimPrefix(a, "Bearer ")
	}
	return r.URL.Query().Get("t")
}

func hLogin(w http.ResponseWriter, r *http.Request) {
	var body struct{ Username, Password string }
	json.NewDecoder(r.Body).Decode(&body)
	// username 생략 시 유일 계정 or "admin" 시도 (구버전 앱 호환)
	name := strings.TrimSpace(body.Username)
	if name == "" {
		name = "admin"
	}
	u := getUser(name)
	if u == nil || subtle.ConstantTimeCompare([]byte(u.Pass), []byte(hashPw(body.Password))) != 1 {
		time.Sleep(600 * time.Millisecond)
		http.Error(w, "아이디나 비밀번호가 틀렸어… ♡", http.StatusUnauthorized)
		return
	}
	tok := makeToken(name)
	http.SetCookie(w, &http.Cookie{
		Name: "sd_auth", Value: tok, Path: "/",
		HttpOnly: true, SameSite: http.SameSiteLaxMode,
		MaxAge: 30 * 24 * 3600,
	})
	writeJSON(w, map[string]any{"ok": true, "token": tok, "user": name, "role": u.Role, "admin": u.isAdmin()})
}
func hLogout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: "sd_auth", Value: "", Path: "/", MaxAge: -1})
	writeJSON(w, map[string]any{"ok": true})
}
func hMe(w http.ResponseWriter, r *http.Request) {
	u := curUser(r)
	writeJSON(w, map[string]any{"ok": true, "user": u.Name, "role": u.Role, "admin": u.isAdmin(), "canWrite": u.canWrite()})
}

// ── path safety ──
func resolveBase(base, rel string) (string, bool) {
	clean := path.Clean("/" + strings.TrimPrefix(rel, "/"))
	full := filepath.Join(base, filepath.FromSlash(clean))
	if full != base && !strings.HasPrefix(full, base+string(os.PathSeparator)) {
		return "", false
	}
	return full, true
}
func resolveU(r *http.Request, rel string) (string, bool) { return resolveBase(rootFor(r), rel) }

type Entry struct {
	Name  string `json:"name"`
	IsDir bool   `json:"isDir"`
	Size  int64  `json:"size"`
	Mod   int64  `json:"mod"`
}

func listDir(full string) ([]Entry, error) {
	des, err := os.ReadDir(full)
	if err != nil {
		return nil, err
	}
	entries := []Entry{}
	for _, d := range des {
		if strings.HasPrefix(d.Name(), ".") {
			continue
		}
		info, err := d.Info()
		if err != nil {
			continue
		}
		entries = append(entries, Entry{d.Name(), d.IsDir(), info.Size(), info.ModTime().Unix()})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].IsDir != entries[j].IsDir {
			return entries[i].IsDir
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	return entries, nil
}

func hList(w http.ResponseWriter, r *http.Request) {
	rel := r.URL.Query().Get("path")
	full, ok := resolveU(r, rel)
	if !ok {
		http.Error(w, "bad path", 400)
		return
	}
	entries, err := listDir(full)
	if err != nil {
		http.Error(w, err.Error(), 404)
		return
	}
	writeJSON(w, map[string]any{"path": path.Clean("/" + strings.TrimPrefix(rel, "/")), "entries": entries})
}

func hMkdir(w http.ResponseWriter, r *http.Request) {
	var b struct{ Path, Name string }
	json.NewDecoder(r.Body).Decode(&b)
	full, ok := resolveU(r, path.Join(b.Path, b.Name))
	if !ok || b.Name == "" {
		http.Error(w, "bad", 400)
		return
	}
	if err := os.Mkdir(full, 0755); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

func hDelete(w http.ResponseWriter, r *http.Request) {
	var b struct{ Path string }
	json.NewDecoder(r.Body).Decode(&b)
	full, ok := resolveU(r, b.Path)
	if !ok || full == rootFor(r) {
		http.Error(w, "bad", 400)
		return
	}
	if err := os.RemoveAll(full); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

func hRename(w http.ResponseWriter, r *http.Request) {
	var b struct{ Path, NewName string }
	json.NewDecoder(r.Body).Decode(&b)
	full, ok := resolveU(r, b.Path)
	if !ok || full == rootFor(r) || b.NewName == "" || strings.ContainsAny(b.NewName, "/\\") {
		http.Error(w, "bad", 400)
		return
	}
	dst := filepath.Join(filepath.Dir(full), b.NewName)
	if err := os.Rename(full, dst); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

func hUpload(w http.ResponseWriter, r *http.Request) {
	rel := r.URL.Query().Get("path")
	dir, ok := resolveU(r, rel)
	if !ok {
		http.Error(w, "bad path", 400)
		return
	}
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	files := r.MultipartForm.File["files"]
	for _, fh := range files {
		src, err := fh.Open()
		if err != nil {
			continue
		}
		name := filepath.Base(fh.Filename)
		dst, err := os.Create(filepath.Join(dir, name))
		if err != nil {
			src.Close()
			http.Error(w, err.Error(), 400)
			return
		}
		io.Copy(dst, src)
		dst.Close()
		src.Close()
	}
	writeJSON(w, map[string]any{"ok": true, "count": len(files)})
}

func hDownload(w http.ResponseWriter, r *http.Request) { serveFile(w, r, true) }
func hRaw(w http.ResponseWriter, r *http.Request)      { serveFile(w, r, false) }

func serveFile(w http.ResponseWriter, r *http.Request, attach bool) {
	full, ok := resolveU(r, r.URL.Query().Get("path"))
	if !ok {
		http.Error(w, "bad", 400)
		return
	}
	sendFile(w, r, full, attach)
}

func sendFile(w http.ResponseWriter, r *http.Request, full string, attach bool) {
	info, err := os.Stat(full)
	if err != nil || info.IsDir() {
		http.Error(w, "not found", 404)
		return
	}
	if attach {
		w.Header().Set("Content-Disposition", "attachment; filename*=UTF-8''"+urlEscape(filepath.Base(full)))
	}
	http.ServeFile(w, r, full)
}

// hStream: ffmpeg으로 브라우저 재생 가능한 fragmented mp4로 실시간 변환.
// 비디오 코덱이 이미 h264면 복사(-c:v copy, CPU 절약), 아니면 libx264 ultrafast.
func hStream(w http.ResponseWriter, r *http.Request) {
	full, ok := resolveU(r, r.URL.Query().Get("path"))
	if !ok {
		http.Error(w, "bad", 400)
		return
	}
	streamFile(w, r, full)
}

func streamFile(w http.ResponseWriter, r *http.Request, full string) {
	if _, err := os.Stat(full); err != nil {
		http.Error(w, "not found", 404)
		return
	}
	vcodec := probeCodec(full)
	varg := []string{"-c:v", "libx264", "-preset", "ultrafast", "-crf", "26",
		"-maxrate", "4M", "-bufsize", "8M", "-vf", "scale='min(1280,iw)':-2"}
	if vcodec == "h264" {
		varg = []string{"-c:v", "copy"} // 이미 h264면 재인코딩 없이 컨테이너만 변경
	}
	args := []string{"-hide_banner", "-loglevel", "error", "-i", full}
	args = append(args, varg...)
	args = append(args, "-c:a", "aac", "-ac", "2", "-b:a", "160k",
		"-movflags", "frag_keyframe+empty_moov+default_base_moof", "-f", "mp4", "pipe:1")
	cmd := exec.CommandContext(r.Context(), "ffmpeg", args...)
	w.Header().Set("Content-Type", "video/mp4")
	w.Header().Set("Cache-Control", "no-store")
	cmd.Stdout = w
	cmd.Stderr = os.Stderr
	cmd.Run() // 클라이언트 끊기면 r.Context() 취소로 ffmpeg 종료
}

func probeCodec(file string) string {
	out, err := exec.Command("ffprobe", "-v", "error", "-select_streams", "v:0",
		"-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1", file).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// ── 썸네일 (ffmpeg: 이미지 리사이즈 / 영상 대표프레임), 디스크 캐시 ──
func hThumb(w http.ResponseWriter, r *http.Request) {
	full, ok := resolveU(r, r.URL.Query().Get("path"))
	if !ok {
		http.Error(w, "bad", 400)
		return
	}
	cache, err := makeThumb(full, 320)
	if err != nil {
		http.Error(w, "no thumb", 415)
		return
	}
	w.Header().Set("Cache-Control", "max-age=86400")
	http.ServeFile(w, r, cache)
}

// makeThumb: 이미지 리사이즈 / 영상 대표프레임 / 음악 앨범아트를 width 폭 jpg로 (디스크 캐시).
// ffmpeg가 못 읽는 파일(zip 등)은 실패 표시를 남겨 다시 시도하지 않는다.
func makeThumb(full string, width int) (string, error) {
	info, err := os.Stat(full)
	if err != nil || info.IsDir() {
		return "", fmt.Errorf("not a file")
	}
	cacheDir := filepath.Join(os.Getenv("HOME"), ".cache", "shinodrive", "thumbs")
	os.MkdirAll(cacheDir, 0755)
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s|%d|%d|%d", full, info.Size(), info.ModTime().Unix(), width)))
	cache := filepath.Join(cacheDir, hex.EncodeToString(sum[:])+".jpg")
	if _, err := os.Stat(cache); err == nil {
		return cache, nil
	}
	if _, err := os.Stat(cache + ".none"); err == nil {
		return "", fmt.Errorf("no thumb")
	}
	cmd := exec.Command("ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
		"-i", full, "-vf", fmt.Sprintf("thumbnail,scale='min(%d,iw)':-2", width), "-frames:v", "1", cache)
	if err := cmd.Run(); err != nil {
		os.Remove(cache)
		os.WriteFile(cache+".none", nil, 0644)
		return "", err
	}
	return cache, nil
}

// ── 검색 (재귀 파일명) ──
func hSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	baseRel := r.URL.Query().Get("path")
	base, ok := resolveU(r, baseRel)
	if !ok || q == "" {
		writeJSON(w, map[string]any{"entries": []Entry{}})
		return
	}
	type SR struct {
		Entry
		Rel string `json:"rel"`
	}
	res := []SR{}
	filepath.WalkDir(base, func(p string, d os.DirEntry, err error) error {
		if err != nil || len(res) >= 200 {
			return nil
		}
		if strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if strings.Contains(strings.ToLower(d.Name()), q) {
			info, _ := d.Info()
			rel := strings.TrimPrefix(p, rootFor(r))
			res = append(res, SR{Entry{d.Name(), d.IsDir(), info.Size(), info.ModTime().Unix()}, filepath.ToSlash(rel)})
		}
		return nil
	})
	writeJSON(w, map[string]any{"entries": res})
}

// ── 폴더 ZIP 다운로드 (스트리밍) ──
func hZip(w http.ResponseWriter, r *http.Request) {
	full, ok := resolveU(r, r.URL.Query().Get("path"))
	if !ok {
		http.Error(w, "bad", 400)
		return
	}
	info, err := os.Stat(full)
	if err != nil || !info.IsDir() {
		http.Error(w, "not a dir", 400)
		return
	}
	name := filepath.Base(full)
	if name == "" || name == "/" {
		name = "shinonas"
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", "attachment; filename*=UTF-8''"+urlEscape(name)+".zip")
	zw := zip.NewWriter(w)
	defer zw.Close()
	filepath.WalkDir(full, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || strings.HasPrefix(d.Name(), ".") {
			return nil
		}
		rel, _ := filepath.Rel(full, p)
		fw, err := zw.Create(filepath.ToSlash(rel))
		if err != nil {
			return nil
		}
		f, err := os.Open(p)
		if err != nil {
			return nil
		}
		io.Copy(fw, f)
		f.Close()
		return nil
	})
}

// ── 시스템 상태 (CPU/RAM/온도) ──
func cpuSample() (total, idle uint64) {
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return
	}
	line := strings.SplitN(string(b), "\n", 2)[0]
	f := strings.Fields(line)
	for i := 1; i < len(f); i++ {
		v, _ := strconv.ParseUint(f[i], 10, 64)
		total += v
		if i == 4 || i == 5 { // idle + iowait
			idle += v
		}
	}
	return
}
func cpuPercent() float64 {
	cpuMu.Lock()
	defer cpuMu.Unlock()
	t, i := cpuSample()
	pt, pi := cpuPrev[0], cpuPrev[1]
	cpuPrev = [2]uint64{t, i}
	if pt == 0 || t <= pt {
		return 0
	}
	dt, di := t-pt, i-pi
	return float64(int((float64(dt-di)/float64(dt))*1000)) / 10
}
func memPct() (used, total int64, pct float64) {
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return
	}
	var mt, ma int64
	for _, ln := range strings.Split(string(b), "\n") {
		f := strings.Fields(ln)
		if len(f) < 2 {
			continue
		}
		v, _ := strconv.ParseInt(f[1], 10, 64)
		if f[0] == "MemTotal:" {
			mt = v * 1024
		} else if f[0] == "MemAvailable:" {
			ma = v * 1024
		}
	}
	used = mt - ma
	if mt > 0 {
		pct = float64(int(float64(used)/float64(mt)*1000)) / 10
	}
	return used, mt, pct
}
func cpuTemp() float64 {
	best := 0.0
	for i := 0; i < 8; i++ {
		b, err := os.ReadFile(fmt.Sprintf("/sys/class/thermal/thermal_zone%d/temp", i))
		if err != nil {
			break
		}
		v, _ := strconv.ParseFloat(strings.TrimSpace(string(b)), 64)
		if v/1000 > best {
			best = v / 1000
		}
	}
	return float64(int(best*10)) / 10
}
func hSys(w http.ResponseWriter, r *http.Request) {
	mu, mt, mp := memPct()
	writeJSON(w, map[string]any{
		"cpu": cpuPercent(), "temp": cpuTemp(),
		"mem": map[string]any{"used": mu, "total": mt, "pct": mp},
	})
}

// ── 공유 링크 ──
func loadShares() {
	b, err := os.ReadFile(filepath.Join(cfgDir, "shares.json"))
	if err == nil {
		json.Unmarshal(b, &shares)
	}
}
func saveShares() {
	b, _ := json.MarshalIndent(shares, "", "  ")
	os.WriteFile(filepath.Join(cfgDir, "shares.json"), b, 0600)
}
func newToken() string {
	b := make([]byte, 9)
	rand.Read(b)
	return hex.EncodeToString(b)
}
func hShare(w http.ResponseWriter, r *http.Request) {
	var b struct{ Path string }
	json.NewDecoder(r.Body).Decode(&b)
	full, ok := resolveU(r, b.Path)
	if !ok {
		http.Error(w, "bad", 400)
		return
	}
	info, err := os.Stat(full)
	if err != nil {
		http.Error(w, "not found", 404)
		return
	}
	tok := newToken()
	rootRel := filepath.ToSlash(strings.TrimPrefix(full, root)) // 전역 root 기준 (공개 접근용)
	if rootRel == "" {
		rootRel = "/"
	}
	rec := shareRec{Path: rootRel, IsDir: info.IsDir(), Name: filepath.Base(full), Owner: curUser(r).Name, Created: time.Now().Unix()}
	sharesMu.Lock()
	shares[tok] = rec
	saveShares()
	sharesMu.Unlock()
	writeJSON(w, map[string]any{"token": tok, "url": "/s/" + tok, "name": rec.Name, "isDir": rec.IsDir})
}
func hShares(w http.ResponseWriter, r *http.Request) {
	sharesMu.Lock()
	defer sharesMu.Unlock()
	list := []map[string]any{}
	for t, rec := range shares {
		list = append(list, map[string]any{"token": t, "path": rec.Path, "name": rec.Name, "isDir": rec.IsDir, "created": rec.Created})
	}
	writeJSON(w, map[string]any{"shares": list})
}
func hUnshare(w http.ResponseWriter, r *http.Request) {
	var b struct{ Token string }
	json.NewDecoder(r.Body).Decode(&b)
	sharesMu.Lock()
	delete(shares, b.Token)
	saveShares()
	sharesMu.Unlock()
	writeJSON(w, map[string]any{"ok": true})
}

func getShare(tok string) (shareRec, bool) {
	sharesMu.Lock()
	defer sharesMu.Unlock()
	r, ok := shares[tok]
	return r, ok
}

func hSharePage(sub fs.FS) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		b, err := fs.ReadFile(sub, "share.html")
		if err != nil {
			http.Error(w, "no", 500)
			return
		}
		tok := strings.Trim(strings.TrimPrefix(r.URL.Path, "/s/"), "/")
		if rec, ok := getShare(tok); ok {
			b = []byte(strings.Replace(string(b), "</head>", ogTags(r, tok, rec)+"</head>", 1))
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(b)
	}
}

// ogTags: 디스코드·카카오톡·당근 등이 링크 미리보기 카드를 만들 때 읽는 Open Graph 태그.
// 이 봇들은 자바스크립트를 실행하지 않으므로 서버가 HTML에 직접 넣어야 한다.
func ogTags(r *http.Request, tok string, rec shareRec) string {
	scheme := "http"
	if r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https" {
		scheme = "https"
	}
	base := scheme + "://" + r.Host
	desc := "SHINODRIVE 공유 파일"
	if full, ok := resolveBase(root, rec.Path); ok {
		if rec.IsDir {
			if entries, err := listDir(full); err == nil {
				desc = fmt.Sprintf("폴더 · %d개 항목", len(entries))
			}
		} else if info, err := os.Stat(full); err == nil {
			desc = "파일 · " + humanBytes(info.Size())
		}
	}
	esc := html.EscapeString
	tags := []string{
		`<meta property="og:type" content="website">`,
		`<meta property="og:site_name" content="SHINODRIVE">`,
		`<meta property="og:title" content="` + esc(rec.Name) + `">`,
		`<meta property="og:description" content="` + esc(desc) + `">`,
		`<meta property="og:url" content="` + esc(base+"/s/"+tok) + `">`,
		`<meta property="og:image" content="` + esc(base+"/sd/"+tok+"/og") + `">`,
		`<meta name="twitter:card" content="summary_large_image">`,
	}
	return strings.Join(tags, "\n") + "\n"
}

func humanBytes(n int64) string {
	const u = 1024
	if n < u {
		return fmt.Sprintf("%d B", n)
	}
	v, i := float64(n), 0
	for v >= u && i < 4 {
		v /= u
		i++
	}
	return fmt.Sprintf("%.1f %s", v, []string{"B", "KB", "MB", "GB", "TB"}[i])
}

// /sd/{token}/{action}?p=subpath  (공개, 인증 불필요)
func hShareData(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/sd/")
	parts := strings.SplitN(rest, "/", 2)
	tok := parts[0]
	action := ""
	if len(parts) > 1 {
		action = parts[1]
	}
	rec, ok := getShare(tok)
	if !ok {
		http.Error(w, "공유가 없거나 만료됐어", 404)
		return
	}
	base, ok := resolveBase(root, rec.Path)
	if !ok {
		http.Error(w, "bad", 400)
		return
	}
	target := base
	if rec.IsDir {
		t, ok := resolveBase(base, r.URL.Query().Get("p"))
		if !ok {
			http.Error(w, "bad", 400)
			return
		}
		target = t
	}
	switch action {
	case "info":
		writeJSON(w, map[string]any{"name": rec.Name, "isDir": rec.IsDir})
	case "list":
		if !rec.IsDir {
			info, _ := os.Stat(base)
			writeJSON(w, map[string]any{"path": "/", "entries": []Entry{{rec.Name, false, info.Size(), info.ModTime().Unix()}}})
			return
		}
		entries, err := listDir(target)
		if err != nil {
			http.Error(w, "404", 404)
			return
		}
		writeJSON(w, map[string]any{"path": path.Clean("/" + strings.TrimPrefix(r.URL.Query().Get("p"), "/")), "entries": entries})
	case "dl":
		sendFile(w, r, target, true)
	case "raw":
		sendFile(w, r, target, false)
	case "stream":
		streamFile(w, r, target)
	case "og": // 링크 미리보기 이미지: 사진·영상·앨범아트면 큰 썸네일, 아니면 기본 카드
		w.Header().Set("Cache-Control", "max-age=3600")
		if !rec.IsDir {
			if cache, err := makeThumb(base, 1200); err == nil {
				http.ServeFile(w, r, cache)
				return
			}
		}
		b, _ := fs.ReadFile(webFS, "web/og-default.png")
		w.Header().Set("Content-Type", "image/png")
		w.Write(b)
	default:
		http.Error(w, "?", 400)
	}
}

// ── 관리자: 유저 관리 ──
func hUsers(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		var b struct{ Username, Password, Role, Home string }
		json.NewDecoder(r.Body).Decode(&b)
		name := strings.TrimSpace(b.Username)
		if name == "" || strings.ContainsAny(name, "/\\ ") || b.Password == "" {
			http.Error(w, "아이디/비번을 확인해줘", 400)
			return
		}
		role := b.Role
		if role != "admin" && role != "editor" && role != "reader" {
			role = "editor"
		}
		home := strings.TrimSpace(b.Home)
		if home == "" && role != "admin" {
			home = name // 개인 폴더 기본값 = 아이디
		}
		usersMu.Lock()
		if users[name] != nil {
			usersMu.Unlock()
			http.Error(w, "이미 있는 아이디야", 409)
			return
		}
		users[name] = &User{Name: name, Pass: hashPw(b.Password), Role: role, Home: home}
		saveUsersLocked()
		usersMu.Unlock()
		if home != "" {
			os.MkdirAll(filepath.Join(root, home), 0755)
		}
		writeJSON(w, map[string]any{"ok": true})
		return
	}
	usersMu.Lock()
	defer usersMu.Unlock()
	list := []map[string]any{}
	for name, u := range users {
		list = append(list, map[string]any{"name": name, "role": u.Role, "home": u.Home})
	}
	sort.Slice(list, func(i, j int) bool { return list[i]["name"].(string) < list[j]["name"].(string) })
	writeJSON(w, map[string]any{"users": list, "me": curUser(r).Name})
}

func hUserDel(w http.ResponseWriter, r *http.Request) {
	var b struct{ Username string }
	json.NewDecoder(r.Body).Decode(&b)
	if b.Username == curUser(r).Name {
		http.Error(w, "자기 자신은 못 지워", 400)
		return
	}
	usersMu.Lock()
	u := users[b.Username]
	if u == nil {
		usersMu.Unlock()
		http.Error(w, "없는 유저", 404)
		return
	}
	if u.Role == "admin" {
		cnt := 0
		for _, x := range users {
			if x.Role == "admin" {
				cnt++
			}
		}
		if cnt <= 1 {
			usersMu.Unlock()
			http.Error(w, "마지막 관리자는 못 지워", 400)
			return
		}
	}
	delete(users, b.Username)
	saveUsersLocked()
	usersMu.Unlock()
	writeJSON(w, map[string]any{"ok": true}) // 홈 폴더는 데이터 보존을 위해 남겨둠
}

// 본인 비밀번호 변경
func hPasswd(w http.ResponseWriter, r *http.Request) {
	var b struct{ Old, New string }
	json.NewDecoder(r.Body).Decode(&b)
	u := curUser(r)
	if subtle.ConstantTimeCompare([]byte(u.Pass), []byte(hashPw(b.Old))) != 1 || b.New == "" {
		http.Error(w, "현재 비번이 틀렸어", 400)
		return
	}
	usersMu.Lock()
	users[u.Name].Pass = hashPw(b.New)
	saveUsersLocked()
	usersMu.Unlock()
	writeJSON(w, map[string]any{"ok": true})
}

func hUsage(w http.ResponseWriter, r *http.Request) {
	total, free := diskUsage(rootFor(r))
	writeJSON(w, map[string]any{"total": total, "used": total - free, "free": free})
}

func serveIndex(sub fs.FS) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		b, err := fs.ReadFile(sub, "index.html")
		if err != nil {
			http.Error(w, "no index", 500)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(b)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func urlEscape(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
