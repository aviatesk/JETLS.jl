# JETLS マルチスレッディング設計ドキュメント

*このドキュメントはClaudeの支援を受けて作成されました。*

## 概要

このドキュメントはJETLSのマルチスレッディング設計について、スレッドセーフティ要件と実装戦略に焦点を当てて説明します。目標は、データの一貫性と正確性を維持しながら、LSPリクエストの並列処理を可能にすることです。

## 設計哲学

- **RCU (Read-Copy-Update)** パターンを基本とする
- 読み取り操作は常にロックフリー（スナップショット読み）
- 書き込み操作は「ロック外で準備 → 短時間で公開」

## `FileInfo`のスレッドセーフティ（ほぼ解決済み）

[aviatesk/JETLS.jl#229](https://github.com/aviatesk/JETLS.jl/pull/229)により`FileInfo`をイミュータブルにし、事前計算されたAST構築を導入したことで、主要なマルチスレッディングの問題が解決されました：

**解決された問題**：
- `mutable struct FileInfo`への同時更新によるデータ競合
- 遅延AST構築による重複計算と競合状態
- `cache_file_info!`における非アトミックなフィールド更新
- 古い`FileInfo`インスタンスのGC問題

```julia
struct FileInfo
    version::Int
    encoding::LSP.PositionEncodingKind.Ty
    parsed_stream::JS.ParseStream
    syntax_node::JS.SyntaxNode
    syntax_tree0::SyntaxTree0
    testsetinfos::Vector{TestsetInfo}  # 注意: ミュータブルなVector
end
```

**既知の軽微な問題**：
`testsetinfos`フィールドのミュータブル性。スレッドセーフなloweringキャッシュの導入時に解決予定。

## RCUベースの設計

### 1. FileCache：URI単位でのRCU

#### 設計原則

- **URIごとの書き込みは逐次**（LSPプロトコル保証）
- **読み取りは完全に並列**（ロックフリー）
- **既存エントリの更新**: URIごとの不変値を新しく公開（エントリ単位の公開境界）
- **構造変化**（追加/削除）: 短いクリティカルセクションでキー集合のスナップショットを更新

#### 実装パターン

```julia
# Per-URI RCUの概念的構造
mutable struct FileEntry
    @atomic info::FileInfo  # アトミック公開される不変値
end

struct FileCache
    entries::RcuCell{Dict{URI,FileEntry}}  # 構造変化はRCU
end

# 読み取り：完全にロックフリー
function get_file_info(cache::FileCache, uri::URI)
    entries = rcu_read(cache.entries)  # スナップショット取得
    entry = get(entries, uri, nothing)
    return entry === nothing ? nothing : @atomic entry.info
end

# 更新：既存エントリはO(1)、新規エントリはRCU
function update_file_info!(cache::FileCache, uri::URI, info::FileInfo)
    entries = rcu_read(cache.entries)
    if (entry = get(entries, uri, nothing)) !== nothing
        # 既存エントリ：アトミック公開のみ
        @atomic entry.info = info
    else
        # 新規エントリ：構造変化なのでRCU
        rcu_update!(cache.entries) do entries
            new_entries = copy(entries)
            new_entries[uri] = FileEntry(info)
            new_entries
        end
    end
end
```

#### 差分（Patch/Delta）の概念

構造変化は不変の差分として表現し、公開時点で線形化：

- **Put**: 既存エントリの更新
- **Insert**: 新規エントリの追加
- **Remove**: エントリの削除
- **Rename**: URI変更（Remove + Insert）
- **条件付き更新**: CAS（Compare-And-Swap）操作

これらの操作は短いクリティカルセクションで適用され、読み手は常に一貫したスナップショットを観測。

### 2. ServerState/FullAnalysis：構造全体でのRCU

#### 設計原則

- **全体をスナップショットとして扱う**
- **読み手は常に「現在または直前の一貫したスナップショット」を見る**
- **重い処理はロック外で実行、公開は瞬時**

#### 実装パターン

```julia
mutable struct ServerState
    # High-frequency caches with per-URI RCU
    const file_cache::FileCache  # URI単位RCU
    const saved_file_cache::SavedFileCache  # URI単位RCU

    # Low-frequency updates with whole-structure RCU
    @atomic analysis_cache::RcuCell{Dict{URI,AnalysisInfo}}
    @atomic extra_diagnostics::RcuCell{ExtraDiagnostics}
    @atomic config_manager::RcuCell{ConfigManager}
    # ...
end

# 分析結果の更新：重い処理はロック外
function update_analysis!(state::ServerState, uri::URI)
    # 1. 現在のスナップショットを読む
    current = rcu_read(state.analysis_cache)

    # 2. 重い分析処理（ロック外）
    new_analysis = perform_heavy_analysis(uri)

    # 3. 短時間で新しいスナップショットを公開
    rcu_update!(state.analysis_cache) do cache
        new_cache = copy(cache)
        new_cache[uri] = new_analysis
        new_cache
    end
end
```

### 3. RCU実装の詳細

```julia
"""
    RcuCell{T}

Read-Copy-Update セル：読みは@atomicロード、コミットは短く線形化。
"""
mutable struct RcuCell{T}
    @atomic ptr::T
    wlock::ReentrantLock  # コミットの直列化のみ
end

# ロックフリー読み取り
@inline rcu_read(c::RcuCell) = @atomic c.ptr

# 短時間のアトミック置換
@inline function rcu_swap!(c::RcuCell{T}, newv::T) where T
    lock(c.wlock) do
        @atomic c.ptr = newv
    end
end

# Read-Modify-Write パターン
function rcu_update!(c::RcuCell{T}, f::Function) where T
    old = rcu_read(c)
    new = f(old)  # 重い処理はロック外
    return rcu_swap!(c, new)
end
```

## メッセージハンドラーの並行性

### 1. 順次処理が必要なメッセージ

#### ライフサイクルメッセージ
プロトコルの正確性を維持するため順次処理が必要：
- `initialize` → `initialized`シーケンス
- `shutdown` → `exit`シーケンス
- `shutdown`後は、`exit`を除くすべてのリクエストを拒否する必要がある

#### ドキュメント同期（URI単位）
LSPプロトコルがURI単位での順次性を保証：
- `textDocument/didOpen`
- `textDocument/didChange`
- `textDocument/didClose`

これらは高速（〜1-2ms）なため、メインループで同期処理。重い分析は内部でスポーン。

#### キャンセルリクエスト
- `$/cancelRequest`通知は進行中の操作を中断すべき

（現在未使用）

### 2. 並列処理可能なメッセージ

読み取り専用またはステートレスなリクエスト：
- `textDocument/completion`
- `textDocument/hover`
- `textDocument/definition`
- `textDocument/references`
- `textDocument/documentHighlight`
- `textDocument/formatting`
- など

### 3. 実装戦略

#### スレッドプール使用ガイドライン
- **`:interactive`プール**: 真に軽量で低レイテンシの操作
  - ドキュメント同期（状態更新のみ）
  - シンプルな通知処理
  - 頻繁にyieldするタスク（I/O操作は自動的にyield）
- **`:default`プール**: 分析や計算を含むあらゆる操作
  - lowering/型推論を含む通常のリクエスト（completion、hoverなど）
  - フル分析（数秒かかる可能性）
  - CPU集約的またはブロッキングの可能性がある操作

#### `runserver`ループでのメッセージ処理
```julia
function runserver(server::Server)
    # ...
    for msg in server.endpoint  # 順次メッセージ処理
        # ライフサイクルメッセージ（runserverで既に順次処理）
        if msg isa InitializeRequest
            handle_InitializeRequest(server, msg)
        elseif msg isa ShutdownRequest
            # ... シャットダウン処理 ...
        # 通常のメッセージ処理
        else
            handle_message(server, msg)
        end
    end
end

function handle_message(server::Server, @nospecialize msg)
    if is_sequential_message(msg)
        # 同期的に処理（高速：約1-2ms）
        handle_sequential_message(server, msg)
        # run_full_analysis!のような重い操作は内部でスポーン
    else
        # デフォルト：並列処理のためにスポーン
        Threads.@spawn handle_message_concurrent(server, msg)
    end
end

# 順次処理が必要なメッセージ
function is_sequential_message(@nospecialize msg)
    msg isa DidOpenTextDocumentNotification ||
    msg isa DidChangeTextDocumentNotification ||
    msg isa DidSaveTextDocumentNotification ||
    msg isa DidCloseTextDocumentNotification ||
    msg isa CancelNotification
end
```

### AnalysisUnitのスレッドセーフティ

```julia
mutable struct FullAnalysisResult
    @atomic staled::Bool      # 古くなったかのフラグ
    @atomic analyzing::Bool   # 分析中フラグ
    # ... 他のフィールド
end

struct AnalysisUnit
    entry::AnalysisEntry
    result::FullAnalysisResult
    lock::ReentrantLock  # 更新の調整用
    pending_request::Base.RefValue{Union{Nothing,NamedTuple}}
end
```

同じAnalysisUnitへの並行リクエスト処理：
1. `analyzing`フラグをアトミックにチェック
2. 分析中なら`pending_request`に保存
3. 分析完了後に保留中のリクエストを再実行

## 実装ロードマップ

### フェーズ1：RCU基盤（実装済み）
1. ✅ FileInfoのイミュータブル化
2. ✅ RcuCellの実装
3. ✅ URI単位RCU（FileCache）の実装
4. ✅ ServerStateのRCU化

### フェーズ2：並列化
1. 独立リクエストの並列処理
2. FullAnalysisの並行制御
3. メッセージハンドラーの選択的並列化

### フェーズ3：最適化（将来）
1. シャーディング（ホットパスの競合削減）
2. ロックフリーデータ構造
3. パフォーマンスチューニング

## パフォーマンス特性

### RCUの利点
- **読み取り**: 完全にロックフリー、ゼロ競合
- **書き込み**: 重い処理はロック外、公開のみ短時間
- **スケーラビリティ**: 読み取り中心のワークロードで線形スケール

### 想定レイテンシ
- FileInfo読み取り：〜1μs（ロックフリー）
- FileInfo更新（既存）：〜10μs（アトミック公開）
- FileInfo更新（新規）：〜100μs（構造変化）
- FullAnalysis：〜40ms（ロック外で処理）

## レガシー/代替案：MustLockパターン

MustLockパターンは、より単純だが競合の多い環境には適さない代替案として存在：

```julia
struct MustLock{T}
    lock::ReentrantLock
    val::T
end

function withlock(func, ml::MustLock)
    @lock ml.lock func(ml.val)
end
```

利点：実装が単純、デバッグが容易
欠点：読み取りも書き込みもロックが必要、競合時のスケーラビリティが低い

## まとめ

JETLSのマルチスレッディング実装は、RCU/アトミック公開を基本とし：

1. **FileCache**: URI単位でのRCU、既存エントリはO(1)更新
2. **ServerState**: 低頻度更新は構造全体のRCU
3. **読み取り**: 常にロックフリー
4. **書き込み**: 重い処理はロック外、公開のみ短時間
5. **将来の最適化**: シャーディングは必要に応じて追加

この設計により、LSPサーバーとして必要な応答性とスループットを両立。
