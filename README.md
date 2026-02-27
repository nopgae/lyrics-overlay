# Lyrics Overlay

macOS 데스크톱 가사 싱크 오버레이 앱.
로컬 MP3 파일 재생 또는 YouTube Music에서 현재 재생 중인 곡을 감지하고,
화면 위에 투명 오버레이로 가사를 한 줄씩 실시간 싱크합니다.

---

## 주요 기능

| 기능 | 설명 |
|------|------|
| 🎵 MP3 재생 | 로컬 MP3/M4A/FLAC 파일 재생 + 정확한 재생 시간 추적 |
| 🎬 YouTube Music | Chrome/Brave/Edge에서 현재 재생 곡 자동 감지 |
| 📄 LRC 파일 | MP3와 같은 폴더의 `.lrc` 파일 자동 로드 |
| 🌐 LRCLIB API | LRC 파일 없을 시 무료 LRCLIB API로 자동 검색 |
| 🪟 오버레이 | 항상 최상위, 반투명 배경, 드래그 이동 |
| ♪ 메뉴바 | Dock 아이콘 없이 메뉴바에서 앱 제어 |

---

## 스크린샷

```
┌─────────────────────────────────────────────────────┐
│         이전 가사 (흐릿하게)                          │
│                                                     │
│       ★  현재 가사 (크고 밝게)  ★                   │
│                                                     │
│         다음 가사 (흐릿하게)                          │
└─────────────────────────────────────────────────────┘
```

> 실제 스크린샷은 추후 추가 예정입니다.

---

## 요구 사항

- macOS 12 Monterey 이상
- Python 3.10 이상
- pip 또는 venv

---

## 설치

```bash
# 1. 저장소 클론
git clone https://github.com/yourname/lyrics-overlay.git
cd lyrics-overlay

# 2. 가상환경 생성 (선택)
python3 -m venv .venv
source .venv/bin/activate

# 3. 의존성 설치
pip install -r requirements.txt

# 4. 앱 실행
python -m lyrics_overlay
```

또는 패키지로 설치:

```bash
pip install -e .
lyrics-overlay
```

---

## YouTube Music 연동 설정

YouTube Music 가사 싱크를 사용하려면 두 가지 권한이 필요합니다.

### 1. Chrome JavaScript 허용

Chrome(또는 Brave/Edge) 메뉴에서:

```
Developer → Allow JavaScript from Apple Events  ✅
```

### 2. macOS 접근성 권한

앱 최초 실행 시 권한 요청 팝업이 나타납니다.
또는 수동으로: **시스템 설정 → 개인 정보 보호 및 보안 → 접근성** → 터미널(또는 Python) 허용

---

## 사용법

1. **앱 실행** → 메뉴바에 `♪` 아이콘이 표시됩니다
2. **컨트롤 패널** → 메뉴바 아이콘 클릭 → "Show Controls"
3. **MP3 재생**: `Open MP3…` 버튼으로 파일 선택 → `Play`
4. **YouTube Music**: Chrome에서 YouTube Music 재생 시 자동 감지
5. **오버레이 이동**: 오버레이 창을 드래그해서 원하는 위치로 이동
6. **투명도 조절**: 컨트롤 패널의 슬라이더

### LRC 파일 사용

MP3 파일과 같은 폴더에 동일한 이름의 `.lrc` 파일을 두면 자동으로 사용됩니다:

```
📁 music/
  ├── song.mp3
  └── song.lrc   ← 자동 로드
```

---

## 프로젝트 구조

```
lyrics-overlay/
├── lyrics_overlay/
│   ├── __init__.py          버전 정보
│   ├── __main__.py          python -m 진입점
│   ├── main.py              앱 델리게이트, 오케스트레이터
│   ├── overlay.py           NSPanel 오버레이 윈도우
│   ├── control_panel.py     컨트롤 패널 UI
│   ├── player.py            pygame MP3 플레이어
│   ├── ytmusic_watcher.py   YouTube Music AppleScript 감지
│   ├── lrc_parser.py        LRC 파일 파서
│   ├── lyrics_fetcher.py    LRCLIB API 클라이언트
│   └── sync_engine.py       재생 시간 → 가사 싱크
├── tests/
├── requirements.txt
├── pyproject.toml
├── LICENSE
└── README.md
```

---

## 라이선스

[MIT License](LICENSE)
