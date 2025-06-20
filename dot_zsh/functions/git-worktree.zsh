# Git worktree間の移動を楽に
gwt() {
    # fzfコマンドの存在をチェック
    if ! command -v fzf >/dev/null 2>&1; then
        echo "エラー: この関数にはfzfが必要です。" >&2
        return 1
    fi

    # --- 1. 現在のワークツリーのルートと相対パスを取得 ---
    local root_dir
    root_dir=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$root_dir" ]; then
        echo "エラー: Gitリポジトリではありません。" >&2
        return 1
    fi
    local current_dir=$(pwd)
    local relative_path=""
    if [[ "$current_dir" == "$root_dir"* ]]; then
        relative_path=${current_dir#$root_dir}
    fi

    # --- 2. 移動先のワークツリーをfzfで選択 ---
    # 現在のワークツリーを除いたリストを作成
    local other_worktrees=$(git worktree list | grep -v " ${root_dir} ")
    if [ -z "$other_worktrees" ]; then
        echo "移動可能な他のワークツリーがありません。"
        return 0
    fi

    # fzfで対話的に選択
    local selected_line=$(echo "$other_worktrees" | fzf --height=10 --prompt="Switch to which worktree?: ")

    # --- 3. 選択されたワークツリーに移動 ---
    if [ -n "$selected_line" ]; then
        # 選択された行からワークツリーのパスだけを抽出
        local selected_worktree_root=$(echo "$selected_line" | awk '{print $1}')
        
        # 最終的な移動先ディレクトリを決定
        local target_dir="$selected_worktree_root"
        # 記憶しておいた相対パスが、移動先のワークツリーにも存在すれば、そこを目的地にする
        if [[ -n "$relative_path" && -d "${selected_worktree_root}${relative_path}" ]]; then
            target_dir="${selected_worktree_root}${relative_path}"
        fi
        
        echo "Switching to: $target_dir"
        cd "$target_dir"
    else
        echo "キャンセルしました。"
    fi
}

# git worktree remove
gwr() {
    # メインのワークツリーは削除対象外にする
    local worktree_to_remove=$(git worktree list | awk 'NR>1 {print $1 " " $3}' | fzf --prompt="Select worktree to REMOVE: " | awk '{print $1}')
    
    if [ -n "$worktree_to_remove" ]; then
        # 最終確認
        read -q "REPLY?Really remove worktree at '$worktree_to_remove'? [y/N] "
        echo
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            echo "Removing worktree: $worktree_to_remove"
            git worktree remove "$worktree_to_remove"
        else
            echo "Canceled."
        fi
    fi
}

# gwc: 既存ブランチ選択と新規ブランチ作成を兼ねる万能版
gwc() {
    local default_copy_files=(".envrc.local" ".env.local")
    local extra_copy_files=()

    # コマンドラインオプションを解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --copy)
                if [ -n "$2" ]; then
                    extra_copy_files+=("$2")
                    shift # --copy を消費
                    shift # ファイル名を消費
                else
                    echo "エラー: --copy オプションにはファイル名が必要です。" >&2
                    return 1
                fi
                ;;
            *)
                echo "エラー: 不明なオプション '$1'" >&2
                return 1
                ;;
        esac
    done
    
    # 最終的なコピー対象リストを結合
    local copy_files=("${default_copy_files[@]}" "${extra_copy_files[@]}")


    if ! command -v fzf >/dev/null 2>&1; then echo "fzf is required"; return 1; fi

    # ★★★ 改善点1: 元のサブディレクトリを記憶 ★★★
    local root_dir=$(git rev-parse --show-toplevel)
    local current_dir=$(pwd)
    local relative_path=""
    # 現在地がリポジトリ内であれば、ルートからの相対パスを計算
    if [[ "$current_dir" == "$root_dir"* ]]; then
        relative_path=${current_dir#$root_dir}
    fi
    # ★★★ ここまで ★★★

    # --- 1. 構造化されたブランチ情報を生成 ---
    local all_branches_meta=$(
        (git for-each-ref --format='[L] %(refname:short)%09%(refname)%09local' 'refs/heads') && \
        (git for-each-ref --format='[R] %(refname:short)%09%(refname)%09remote' 'refs/remotes' | grep -v '/HEAD$')
    )
    local used_refs=$(git worktree list --porcelain | grep '^branch ' | awk '{print $2}')
    local available_branches_meta=$(grep -v -F -f <(echo "$used_refs") <(echo "$all_branches_meta"))

    # --- 2. fzfでユーザーに選択させる ---
    local header="[Enter] 選択 | [Option+Enter] 新規作成"
    local preview_command="git log --oneline --color=always -10 {2} 2>/dev/null"
    local selection=$(echo "$available_branches_meta" | fzf --with-nth=1 --delimiter=$'\t' --height=20 \
        --prompt="Select Branch > " --header="$header" --preview="$preview_command" --preview-window=right:50% \
        --bind "alt-enter:print-query")

    if [ $? -ne 0 ]; then echo "Canceled."; return 1; fi
    if [ -z "$selection" ]; then echo "Selection was empty. Canceled."; return 1; fi

    local project_name=$(basename "$root_dir")
    local worktree_path

    # --- 3. ユーザーの選択に応じて処理を分岐 ---
    if echo "$selection" | grep -q -F $'\t'; then
        local display_name=$(echo "$selection" | awk -F$'\t' '{print $1}')
        local full_ref=$(echo "$selection" | awk -F$'\t' '{print $2}')
        local branch_type=$(echo "$selection" | awk -F$'\t' '{print $3}')
        local local_branch_name
        
        if [ "$branch_type" = "local" ]; then
            local_branch_name=$(echo "$full_ref" | sed 's:^refs/heads/::')
            local dir_name="${project_name}-$(echo "$local_branch_name" | sed 's/\//-/g')"
            worktree_path="${root_dir}/../${dir_name}"
            git worktree add "$worktree_path" "$local_branch_name"
        elif [ "$branch_type" = "remote" ]; then
            local_branch_name=$(echo "$full_ref" | sed 's:^refs/remotes/[^/]\+/::')
            local dir_name="${project_name}-$(echo "$local_branch_name" | sed 's/\//-/g')"
            worktree_path="${root_dir}/../${dir_name}"
            echo "Creating new local branch '$local_branch_name' to track '$display_name'..."
            git worktree add -b "$local_branch_name" "$worktree_path" "$full_ref"
        fi
    else
        local branch="$selection"
        local dir_name="${project_name}-$(echo "$branch" | sed 's/\//-/g')"
        worktree_path="${root_dir}/../${dir_name}"
        echo "'$branch' is a new branch."
        local all_branches_raw=$(echo "$all_branches_meta" | awk -F$'\t' '{print $1}')
        local default_base_display_name=""
        if echo "$all_branches_raw" | grep -xqF "[L] develop"; then
            default_base_display_name="[L] develop"
        elif echo "$all_branches_raw" | grep -xqF "[L] main"; then
            default_base_display_name="[L] main"
        elif echo "$all_branches_raw" | grep -xqF "[L] master"; then
            default_base_display_name="[L] master"
        fi
        local sorted_base_branch_list
        if [ -n "$default_base_display_name" ]; then
            sorted_base_branch_list=$( (echo "$default_base_display_name"; echo "$all_branches_raw" | grep -v -x -F "$default_base_display_name") )
        else
            sorted_base_branch_list=$all_branches_raw
        fi
        local base_selection=$(echo "$sorted_base_branch_list" | fzf --height=10 --prompt="Create from which base branch?: ")
        if [ $? -ne 0 ] || [ -z "$base_selection" ]; then echo "Canceled."; return 1; fi
        local base_ref=$(echo "$all_branches_meta" | grep -F "$base_selection" | head -n 1 | awk -F$'\t' '{print $2}')
        git worktree add -b "$branch" "$worktree_path" "$base_ref"
    fi

    
    # --- 4. セットアップコマンドの実行 ---
    if [ $? -eq 0 ]; then
        local find_name_args=()
        if [ ${#copy_files[@]} -gt 0 ]; then
            local first=true
            for file in "${copy_files[@]}"; do
                if ! $first; then find_name_args+=("-o"); fi
                find_name_args+=("-name" "$file")
                first=false
            done
        fi
        
        if [ ${#find_name_args[@]} -gt 0 ]; then
            echo "\nSearching for and copying local config files: ${copy_files[*]}"
            local find_grouped_args=(\( "${find_name_args[@]}" \))
            find "$root_dir" -path "$root_dir/.git" -prune -o -path "$root_dir/node_modules" -prune -o "${find_grouped_args[@]}" -print | while read -r src_file; do
                local rel_path_of_file=${src_file#$root_dir}
                local dest_file="${worktree_path}${rel_path_of_file}"
                mkdir -p "$(dirname "$dest_file")"
                if cp "$src_file" "$dest_file"; then
                    echo "  Copied .${rel_path_of_file}"
                fi
            done
        fi

        # 最終的な移動先ディレクトリを決定
        local target_dir="$worktree_path"
        if [[ -n "$relative_path" && -d "${worktree_path}${relative_path}" ]]; then
            target_dir="${worktree_path}${relative_path}"
        fi

        echo "\nChanging to target directory and running setup..."
        cd "$target_dir" && {
            if command -v direnv >/dev/null 2>&1 && [ -f ".envrc" ]; then direnv allow .; fi
            if command -v aqua >/dev/null 2>&1 && [ -f "aqua.yaml" ]; then aqua policy allow; fi
            if command -v pnpm >/dev/null 2>&1 && [ -f "pnpm-lock.yaml" ]; then pnpm i; fi
        }
        # ★★★ ここまで ★★★
    else
        echo "Worktree creation failed. Skipping setup."
    fi
}
