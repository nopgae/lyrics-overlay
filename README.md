# Lyrics Overlay

macOS 데스크톱 가사 싱크 오버레이 앱.
로컬 MP3 파일 재생 또는 YouTube Music에서 현재 재생 중인 곡을 감지하고,
화면 위에 투명 오버레이로 가사를 한 줄씩 실시간 싱크합니다.

---

## 주요 기능

| 기능 | 설명 |
|------|------|
| 🎵 MP3 재생 | 로컬 MP3/M4A/FLAC 파일 재생 + 정확한 재생 시간 추적 |
| 🎬 YouTube Music | Chrome/Brave/Edge/Safari에서 현재 재생 곡 자동 감지 |
| 📄 LRC 파일 | MP3와 같은 폴더의 `.lrc` 파일 자동 로드 |
| 🌐 LRCLIB API | LRC 파일 없을 시 무료 LRCLIB API로 자동 검색 |
| 🪟 오버레이 | 항상 최상위, 반투명 배경, 드래그 이동, 2줄 자동 줄바꿈 |
| 🍎 앱 메뉴 | macOS 왼쪽 상단 메뉴바 (Show Controls / Toggle Overlay / Quit) |
| ♪ 메뉴바 아이콘 | 상단 상태바에서 빠른 접근 |

---

## 스크린샷

```
┌─────────────────────────────────────────────────────┐
│         이전 가사 (흐릿하게)                          │
│                                                     │
│       ★  현재 가사 (크고 밝게)  ★                   │
│         긴 가사는 자동으로 줄바꿈됩니다               │
│                                                     │
│         다음 가사 (흐릿하게)                          │
└─────────────────────────────────────────────────────┘
```

> 실제 스크린샷은 추후 추가 예정입니다.

---

## 요구 사항

- macOS 12 Monterey 이상
- Python 3.10 이상

---

## 설치 및 실행

```bash
# 1. 저장소 클론
git clone https://github.com/nopgae/lyrics-overlay.git
cd lyrics-overlay

# 2. 의존성 설치
pip install -r requirements.txt

# 3. 실행 (.app 번들로 — Dock 이름/아이콘 정상 표시)
open "dist/Lyrics Overlay.app"

# 또는 터미널에서 직접 실행
python -m lyrics_overlay
```

### .app 번들 설치 (권장)

```bash
cp -r "dist/Lyrics Overlay.app" /Applications/
```

이후 Spotlight(`⌘ Space`) → `Lyrics Overlay` 로 실행.

> **참고**: `python -m` 방식으로 실행하면 Dock/메뉴바 이름이 "Python"으로 표시됩니다.
> Dock 이름을 "Lyrics Overlay"로 표시하려면 `.app` 번들로 실행하세요.

---

## YouTube Music 연동 설정

### Chrome / Brave / Edge
**Developer → Allow JavaScript from Apple Events** ✅

### Safari
1. Safari → **Settings (⌘,)** → **Advanced** → "Show features for web developers" 체크
2. **Develop → Allow JavaScript from Apple Events** ✅

### macOS 접근성 권한
**시스템 설정 → 개인 정보 보호 및 보안 → 접근성** → 터미널(또는 Python) 허용

---

## 사용법

1. **앱 실행** → Dock에 Lyrics Overlay 아이콘, 메뉴바에 `♪` 아이콘 표시
2. **컨트롤 패널** → 메뉴바 `♪` 또는 왼쪽 상단 **Lyrics Overlay → Show Controls** (`⌘,`)
3. **MP3 재생**: `Open MP3…` → 파일 선택 → `Play`
4. **YouTube Music**: Chrome/Safari에서 재생 시 자동 감지 및 가사 표시
5. **오버레이 이동**: 오버레이 창 드래그
6. **투명도 조절**: 컨트롤 패널 슬라이더

### 메뉴바 단축키

| 단축키 | 기능 |
|--------|------|
| `⌘,` | Show Controls |
| `⌘/` | Toggle Overlay |
| `⌘H` | Hide |
| `⌘Q` | Quit |

### LRC 파일 사용

MP3 파일과 같은 폴더에 동일한 이름의 `.lrc` 파일을 두면 자동으로 사용됩니다:

```
📁 music/
  ├── song.mp3
  └── song.lrc   ← 자동 로드 (LRCLIB API보다 우선)
```

---

## 프로젝트 구조

```
lyrics-overlay/
├── lyrics_overlay/
│   ├── __init__.py          버전 정보
│   ├── __main__.py          python -m 진입점
│   ├── main.py              앱 델리게이트, 타이머, ObjC 액션 메서드
│   ├── overlay.py           NSPanel 오버레이 (always-on-top, 투명, 드래그)
│   ├── control_panel.py     컨트롤 패널 UI
│   ├── player.py            pygame MP3 플레이어
│   ├── ytmusic_watcher.py   YouTube Music AppleScript 감지 (Chrome/Safari)
│   ├── lrc_parser.py        LRC 파일 파서
│   ├── lyrics_fetcher.py    LRCLIB API 클라이언트
│   └── sync_engine.py       재생 시간 → 가사 싱크
├── dist/
│   └── Lyrics Overlay.app   macOS 앱 번들
├── run.py                   .app 번들 런처
├── setup.py                 py2app 설정
├── requirements.txt
├── pyproject.toml
├── LICENSE
└── README.md
```

---

## 라이선스

[MIT License](LICENSE)
