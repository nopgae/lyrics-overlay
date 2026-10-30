# Lyric Fever 참고 노트

> Python(PyObjC) 버전 시절에 쓴 노트다. 현재 앱은 Swift로 다시 작성됐고, 아래 "적용안" 대부분(분산 알림 등)이 반영됐다.

[aviwad/LyricFever](https://github.com/aviwad/LyricFever) (MIT, Swift/SwiftUI) 소스 분석.
메뉴바 가사 컨셉은 유지하고, 구조와 아이디어만 Python/PyObjC로 옮겨 적용한다.

## 1. 재생 감지: 폴링 대신 분산 알림

| 항목 | Lyric Fever | Lyrics Overlay (현재) |
|---|---|---|
| 곡 변경·재생/일시정지 | `DistributedNotificationCenter` 구독 (`LyricFever.swift:98`) | 1초마다 AppleScript 폴링 |
| Music.app 알림 | `com.apple.Music.playerInfo` — userInfo: `Player State`, `Name`, `Artist`, `Album` | — |
| Spotify 알림 | `com.spotify.client.PlaybackStateChanged` — userInfo: `Player State`, `Track ID`, `Name` | 미지원 |
| 재생 위치 | 필요할 때만 ScriptingBridge로 `playerPosition` 조회 | 매 폴링마다 조회 후 보간 |

**적용안:** `NSDistributedNotificationCenter.defaultCenter().addObserver_selector_name_object_`로
두 알림을 구독. 알림이 오면 그때 한 번만 위치를 조회하고, 이후엔 보간한다.
YouTube Music(브라우저)은 알림이 없으므로 폴링을 유지하되, Music/Spotify가 재생 중이면 건너뛴다.
→ Spotify 지원이 거의 공짜로 생기고, AppleScript 호출이 초당 1회 → 곡 변경 시 1회로 줄어든다.

## 2. 가사 타이밍: 고정 틱 대신 다음 줄까지 sleep

`ViewModel.lyricUpdater()` (`ViewModel.swift:764`)는 다음 가사의 시작 시각까지 정확히 잠든 뒤 인덱스를 넘긴다.
250ms 틱보다 CPU를 덜 쓰고, 줄이 바뀌는 시점의 오차가 최대 250ms → 거의 0이 된다.
(작성자 주장 CPU 0.1% vs LyricsX 3%)

**적용안:** `syncTick`(250ms 반복)을 "다음 줄 시각까지 일회성 NSTimer" 방식으로 교체.
일시정지/탐색/곡 변경 시 타이머를 취소하고 재계산.

## 3. 싱크 오프셋

- 플레이어별 기본 보정: Music.app `+400ms`, 애니메이션 표시 시 `+400ms`, AirPlay 토글 시 `−2000ms`
  (`AppleMusicPlayer.currentTime`, `SpotifyPlayer.currentTime`)
- 메뉴에서 오프셋 ±100ms 조정 버튼 + 현재 값 표시 ("Offset is N ms")

**적용안:** 우리 `_LYRIC_OFFSET = 0.2` 고정값을 메뉴의 "싱크 조정 ±0.1s / 초기화"로 대체하고
`NSUserDefaults`에 저장. "블루투스/AirPlay 지연" 토글도 추가.

## 4. 메뉴바 라벨 규칙 (`MenubarLabelView.swift`)

우선순위:
1. 재생 중이고 가사 있음 → 현재 가사 (번역 > 로마자 > 원문)
2. 가사 없음 + "곡 정보 표시" 옵션 → `Now Playing: 곡 - 아티스트` / 일시정지면 `Now Paused: …`
3. 그 외 → 아이콘만 (`music.note.list`)

긴 가사는 `truncationLength`(기본 40자, 메뉴에서 조절)로 자르고 `…`를 붙인다.

**비교:** 우리는 56자 단위로 나눠 1.5초마다 순환한다. 순환 방식은 유지하되,
2번(가사 없을 때 곡 정보)과 길이 조절 메뉴는 가져올 만하다.

## 5. 메뉴바 클릭 시 메뉴 구성 (`MenubarWindowView.swift`)

재생 컨트롤(이전/재생/다음, 볼륨) · 가사 표시 토글 · 노래방 창 · 전체화면 · 번역/로마자 토글 ·
오프셋 조정 · 메뉴바 길이 · 설정 · 업데이트 확인 · 종료.

**적용안 (우선순위순):** 지금 재생 중 표시 → 오버레이/메뉴바 모드 → 전체 가사 →
싱크 조정 → 가사 다시 검색 → 소스 선택 → 설정 → 종료.
상태 아이템을 클릭하면 모드를 전환하던 기존 동작은 메뉴의 한 항목으로 옮긴다.

## 6. 가사 검색

- 제공자 순서: Spotify 내부 API(로그인 필요) → LRCLIB → NetEase. 결과는 CoreData에 영구 캐시.
- LRCLIB `/api/get`에 아티스트·곡·**앨범**을 함께 보냄 → 정확도 향상.
- 곡 변경 시 이전 fetch Task를 `cancel()` (`ViewModel.fetch`, `currentFetchTask?.cancel()`).
- 검색 창에서 사용자가 직접 다른 가사를 골라 덮어쓸 수 있음 (`SearchWindow.swift`).

**적용 완료 (이번 수정):** 앨범 전달, 이전 요청 결과 폐기(세대 번호), 길이 검증, 제목 정리.
**남은 것:** 디스크 영구 캐시(JSON 파일, `~/Library/Application Support/Lyrics Overlay/`),
수동 가사 검색/선택 창.

## 진행 상황

- [x] 분산 알림 기반 감지 + Spotify 지원 (1번) — 알림 시 즉시 조회, 앱 소스 재생 중엔 4초마다만 재조회
- [x] 상태 아이템 메뉴 + 싱크 오프셋 (3·5번) — 오프셋은 `lyricOffset` 기본값으로 저장
- [x] 가사 없을 때 메뉴바에 곡 정보 표시 (4번)
- [ ] 다음 줄까지 sleep 하는 타이머 (2번)
- [ ] 디스크 캐시, 수동 가사 선택 (6번)
- [ ] AirPlay/블루투스 지연 토글 (3번)
