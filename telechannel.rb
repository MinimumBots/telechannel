require 'bundler/setup'
require 'yaml'
require 'discordrb'
require 'discordrb/webhooks'

class Telechannel
  MESSAGES_FILE = File.expand_path('../messages.yml', __FILE__)
  MESSAGES_LIST = File.open(MESSAGES_FILE, 'r') { |f| YAML.load(f) }
  REQUIRE_PERMIT = {
    manage_webhooks: "ウェブフックの管理",
    read_messages: "メッセージを読む",
    send_messages: "メッセージを送信",
    manage_messages: "メッセージの管理",
    embed_links: "埋め込みリンク",
    read_message_history: "メッセージ履歴を読む",
    add_reactions: "リアクションの追加",
  }

  def initialize(bot_token)
    @link_pairs  = Hash.new { |hash, key| hash[key] = {} }  # 接続済み

    @bot = Discordrb::Commands::CommandBot.new(
      token: bot_token,
      prefix: "/",
      help_command: false,
      webhook_commands: false,
      ignore_bots: true
    )

    # BOT初期化処理
    @bot.ready do
      @bot.game = "#{@bot.prefix}connect"
      @webhook_icon = @bot.profile.avatar_url
      resume_links
    end

    # コネクション作成
    @bot.command(:connect) do |event, p_channel_id|
      next unless check_permission(event.channel, event.author)
      next unless p_channel = get_arg(event.channel, p_channel_id)

      new_link(event, p_channel)
      nil
    end

    # コネクション削除
    @bot.command(:disconnect) do |event, p_channel_id|
      next unless check_permission(event.channel, event.author)
      next unless p_channel = get_arg(event.channel, p_channel_id)

      remove_link(event, p_channel)
      nil
    end

    # 接続中のチャンネルを表示
    @bot.command(:connecting) do |event|
      listing_links(event)
      nil
    end

    # BOTに必要な権限の検証
    @bot.command(:connectable) do |event|
      test_permittion(event.channel)
      nil
    end

    # メッセージイベント
    @bot.message do |event|
      transfer_message(event)
      nil
    end

    # 招待コマンド
    @bot.mention do |event|
      next if event.content !~ /^<@!?\d+> *invite/
      channel = event.author.pm
      channel.send_embed do |embed|
        invite = MESSAGES_LIST[:invite]
        embed.color = invite[:color]
        embed.title = invite[:title]
        embed.description = invite[:description]
      end
    end

    # デバッグコマンド
    @bot.mention(in: ENV['ADMIN_CHANNEL_ID'].to_i, from: ENV['ADMIN_USER_ID'].to_i) do |event|
      next if event.content !~ /^<@!?\d+> admin (.+)/

      begin
        value = eval($1)
      rescue => exception
        value = exception
      end
      event << "```\n#{value}\n```"
    end
  end

  # BOT起動
  def run(async = false)
    @bot.run(async)
  end

  private

  # 実行権限チェック
  def check_permission(channel, member)
    return unless member.is_a?(Discordrb::Member)
    return unless member.permission?(:manage_channels, channel)
    true
  end

  # 引数のチャンネルを取得
  def get_arg(channel, arg)
    # ヘルプ表示(パラメータなし)
    if arg.nil?
      channel.send_embed do |embed|
        help = MESSAGES_LIST[:help]
        embed.color = help[:color]
        embed.title = help[:title]
        embed.description = help[:description]
      end
      return
    end

    # チャンネルが指定されていない
    if arg !~ /^(\d+)$/ && arg !~ /^<#(\d+)>$/
      channel.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ チャンネルIDを指定してください"
        embed.description = "コマンドのパラメータにチャンネルID、またはチャンネルメンションを指定してください。"
      end
      return
    end

    # チャンネルIDを解決できるか
    begin
      p_channel = @bot.channel($1)
    rescue; nil; end

    if p_channel.nil?
      channel.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ 指定されたチャンネルが見つかりません"
        embed.description = "指定したチャンネルが存在しないか、BOTが導入されていません。"
      end
      return
    end

    # チャンネルが同一ではないか
    if channel == p_channel
      channel.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ 指定されたチャンネルはこのチャンネルです"
        embed.description = "このチャンネル自身に対して接続することはできません。"
      end
      return
    end

    p_channel
  end

  #================================================

  # 新しい接続
  def new_link(event, p_channel)
    channel = event.channel
    user = event.author

    # 接続切り替え
    return unless link_validation(channel, p_channel, user)

    # 接続方法選択
    mutual, send = link_select(channel, p_channel, user)
    return if mutual.nil?

    # 相手チャンネル上のメンバーデータ
    p_member = @bot.member(p_channel.server, user.id)
    # 相手チャンネル上で権限を持つか
    p_permit = !p_member.nil? && p_member.permission?(:manage_channels, channel)

    # 相手チャンネル上で権限を持たないとき
    unless p_permit
      return if (p_member = link_confirmation(channel, p_channel)).nil?
    end

    # 相互接続・一方向接続(送信側)の場合
    if mutual || send
      return if link_create_other(channel, p_channel, p_permit).nil?
    end

    # 自チャンネルのリンクを作成
    if send || create_link(channel, p_channel)
      link_success(channel, p_channel, mutual, send, user, p_member)
    else
      link_failure(channel, p_channel, mutual, p_permit)
    end
  end

  # 接続済み検証
  def link_validation(channel, p_channel, user)
    receive = @link_pairs[p_channel.id].has_key?(channel.id)
    send    = @link_pairs[channel.id].has_key?(p_channel.id)

    if receive || send
      channel.send_embed do |embed|
        embed.color = 0x3b88c3
        embed.title = "ℹ️ すでに接続されています"

        embed.description = "**#{gen_channel_disp(channel, p_channel)}** と "
        if receive && send
          embed.description += "**相互接続** されています。"
        else
          embed.description += "**一方向接続(#{send ? "送" : "受" }信側)** されています。"
        end
        embed.description += "\n\n切断は `/disconnect #{p_channel.id}` で行えます。"
      end
      return
    end

    true
  end

  # 接続方式の選択
  def link_select(channel, p_channel, user)
    message = channel.send_embed do |embed|
      embed.color = 0x3b88c3
      embed.title = "🆕 ##{p_channel.name} との接続方法を選んでください(1分以内)"
      embed.description = "↔️ **相互接続**\n  相手チャンネルと互いにメッセージを送信します\n\n"
      embed.description += "⬅️ **一方向接続(受信側)**\n相手チャンネルのメッセージをこのチャンネルへ送信します\n\n"
      embed.description += "➡️ **一方向接続(送信側)**\nこのチャンネルのメッセージを相手チャンネルへ送信します"
    end
    message.create_reaction("↔️")
    message.create_reaction("⬅️")
    message.create_reaction("➡️")

    # 選択待ち
    mutual = nil; send = nil
    await_event = @bot.add_await!(Discordrb::Events::ReactionAddEvent, { timeout: 60 }) do |event|
      next if event.message != message || event.user != user
      next if event.emoji.name !~ /[↔️⬅️➡️]/
      mutual = event.emoji.name == "↔️"
      send   = event.emoji.name == "➡️"
      true
    end
    message.delete

    return if await_event.nil?  # イベントタイムアウト

    return mutual, send
  end

  # 接続承認処理
  def link_confirmation(channel, p_channel)
    message = channel.send_embed do |embed|
      embed.color = 0x3b88c3
      embed.title = "ℹ️ 相手チャンネルでコマンドを実行してください(10分以内)"
      embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
      embed.description += " で以下のコマンドを実行してください。\n**`/connector #{channel.id}`**"
    end

    # 承認コマンド入力待ち
    p_member = nil
    await_event = p_channel.await!({ timeout: 600, content: "/connector #{channel.id}" }) do |event|
      p_member = event.author
      p_member.permission?(:manage_channels, p_channel)
    end
    message.delete

    # イベントタイムアウト
    if await_event.nil?
      channel.send_embed do |embed|
        embed.color = 0xbe1931
        embed.title = "⛔ 接続待ちがタイムアウトしました"
        embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
        embed.description += " で5分以内に相手チャンネルで指定コマンドの実行がありませんでした。\n最初からコマンドを実行しなおしてください。"
      end
      return
    end

    p_member
  end

  # 相手側のリンクを作成
  def link_create_other(channel, p_channel, p_permit)
    unless create_link(p_channel, channel)
      channel.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ 相手チャンネルと接続できませんでした"
        embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
        embed.description += " でBOTの権限が十分か確認し、最初からコマンドを実行しなおしてください。"
      end

      # 承認コマンドを要求していた場合
      unless p_permit
        channel.send_embed do |embed|
          embed.color = 0xffcc4d
          embed.title = "⚠️ 相手チャンネルと接続できませんでした"
          embed.description = "**このチャンネル** でBOTの権限が十分か確認し、最初からコマンドを実行しなおしてください。"
        end
      end
      return
    end

    true
  end

  # 接続成功
  def link_success(channel, p_channel, mutual, send, user, p_user)
    channel.send_embed do |embed|
      embed.color = 0x77b255
      embed.title = "✅ 相手チャンネルと接続しました"

      embed.description = "**#{gen_channel_disp(channel, p_channel)}** と "
      if mutual
        embed.description += "**相互接続** しました。"
      else
        embed.description += "**一方向接続(#{send ? "送" : "受" }信側)** しました。"
      end
      embed.description += "\n\n切断は `/disconnect #{p_channel.id}` で行えます。"

      embed.footer = Discordrb::Webhooks::EmbedFooter.new(
        text: user.distinct,
        icon_url: user.avatar_url
      )
    end

    p_channel.send_embed do |embed|
      embed.color = 0x77b255
      embed.title = "✅ 相手チャンネルと接続しました"

      embed.description = "**#{gen_channel_disp(p_channel, channel)}** と "
      if mutual
        embed.description += "**相互接続** しました。"
      else
        embed.description += "**一方向接続(#{send ? "受" : "送" }信側)** しました。"
      end
      embed.description += "\n\n切断は `/disconnect #{channel.id}` で行えます。"

      embed.footer = Discordrb::Webhooks::EmbedFooter.new(
        text: p_user.distinct,
        icon_url: p_user.avatar_url
      )
    end
  end

  # 接続失敗
  def link_failure(channel, p_channel, mutual, p_permit)
    destroy_link(p_channel, channel) if mutual  # 相手チャンネルのリンクをロールバック

    channel.send_embed do |embed|
      embed.color = 0xffcc4d
      embed.title = "⚠️ 相手チャンネルと接続できませんでした"
      embed.description = "**このチャンネル** でBOTの権限が十分か確認し、最初からコマンドを実行しなおしてください。"
    end

    # 承認コマンドを要求していた場合
    unless p_permit
      channel.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ 相手チャンネルと接続できませんでした"
        embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
        embed.description += " でBOTの権限が十分か確認し、最初からコマンドを実行しなおしてください。"
      end
    end
  end

  #================================================

  # 接続の切断
  def remove_link(event, p_channel)
    channel = event.channel
    user = event.author

    destroy_link(channel, p_channel)
    destroy_link(p_channel, channel)

    channel.send_embed do |embed|
      embed.color = 0xbe1931
      embed.title = "⛔ 接続が切断されました"
      embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
      embed.description += " と接続が切断されました。"
      embed.footer = Discordrb::Webhooks::EmbedFooter.new(
        text: user.distinct,
        icon_url: user.avatar_url
      )
    end

    p_channel.send_embed do |embed|
      embed.color = 0xbe1931
      embed.title = "⛔ 接続が切断されました"
      embed.description = "**#{gen_channel_disp(p_channel, channel)}**"
      embed.description += " と接続が切断されました。"
      embed.footer = Discordrb::Webhooks::EmbedFooter.new(
        text: user.distinct,
        icon_url: user.avatar_url
      )
    end
  end

  #================================================

  # 接続の再開
  def resume_links
    @bot.servers.each do |_, server|
      begin
        server.webhooks.each do |webhook|
          next if webhook.owner != @bot.profile

          channel = webhook.channel
          begin
            p_channel = @bot.channel(webhook.name[/Telehook<(\d+)>/, 1])
          rescue
            webhook.delete("Lost connection channel")

            channel.send_embed do |embed|
              embed.color = 0xbe1931
              embed.title = "⛔ 接続が切断されました"
              embed.description = "相手チャンネルが見つからないため、接続が切断されました。"
            end
          end

          @link_pairs[p_channel.id][channel.id] = webhook
        end
      rescue; nil; end
    end
  end

  #================================================

  # 接続作成
  def create_link(channel, p_channel)
    webhook = channel.create_webhook(
      "Telehook<#{p_channel.id}>",
      @webhook_icon,
      "To connect with #{p_channel.server.name} ##{p_channel.name}"
    )

    @link_pairs[p_channel.id][channel.id] = webhook
  end

  # 接続削除
  def destroy_link(channel, p_channel)
    webhook = @link_pairs[p_channel.id].delete(channel.id)

    begin
      webhook.delete("To disconnect with #{p_channel.server.name} ##{p_channel.name}")
    rescue; nil; end
  end

  # 接続相手喪失
  def lost_link(channel, p_channel_id)
    @link_pairs[channel.id].delete(p_channel_id)
    webhook = @link_pairs[p_channel_id].delete(channel.id)

    begin
      webhook.delete("Lost connection channel")
    rescue; nil; end
  end

  #================================================

  # メッセージ転送
  def transfer_message(event)
    channel = event.channel
    message = event.message

    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      begin
        p_channel = @bot.channel(p_channel_id)
      rescue
        lost_link(channel, p_channel_id)
        channel.send_embed do |embed|
          embed.color = 0xbe1931
          embed.title = "⛔ 接続が切断されました"
          embed.description = "相手チャンネルが見つからないため、接続が切断されました。"
        end
      end

      client = Discordrb::Webhooks::Client.new(id: p_webhook.id, token: p_webhook.token)
      begin
        # メッセージ送信
        unless message.content.empty?
          client.execute do |builder|
            builder.avatar_url = message.author.avatar_url
            builder.username = gen_webhook_username(channel, p_channel, message.author)
            builder.content = message.content
          end
        end

        # 添付ファイル(CDNのURL)送信
        unless message.attachments.empty?
          client.execute do |builder|
            builder.avatar_url = message.author.avatar_url
            builder.username = gen_webhook_username(channel, p_channel, message.author)
            builder.content = "⬆️ **添付ファイル**\n"
            message.attachments.each do |attachment|
              builder.content += attachment.spoiler? ? "||#{attachment.url}||\n" : "#{attachment.url}\n"
            end
          end
        end
      rescue RestClient::NotFound
        destroy_link(channel, p_channel)
        destroy_link(p_channel, channel)

        channel.send_embed do |embed|
          embed.color = 0xbe1931
          embed.title = "⛔ 接続が切断されました"
          embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
          embed.description += " のウェブフックが見つからないため、接続が切断されました。"
        end

        p_channel.send_embed do |embed|
          embed.color = 0xbe1931
          embed.title = "⛔ 接続が切断されました"
          embed.description = "**#{gen_channel_disp(p_channel, channel)}**"
          embed.description += " のウェブフックが見つからないため、接続が切断されました。"
        end
      end
    end
  end

  #================================================

  # 接続済みリストを表示
  LINK_MODE_ICONS = { mutual: "↔️", send: "➡️", receive: "⬅️" }
  def listing_links(event)
    channel = event.channel

    link_list = {}
    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      begin
        p_channel = @bot.channel(p_channel_id)
      rescue; next; end
      link_list[p_channel.id] = { name: gen_channel_disp(channel, p_channel), mode: :send }
      link_list[p_channel.id][:mode] = :mutual if @link_pairs[p_channel.id][channel.id]
    end

    @link_pairs.each do |p_channel_id, pair_data|
      next if link_list[p_channel_id]

      if pair_data.find {|channel_id, _| channel_id == channel.id }
        begin
          p_channel = @bot.channel(p_channel_id)
        rescue; next; end
        link_list[p_channel.id] = { name: gen_channel_disp(channel, p_channel), mode: :receive }
      end
    end

    if link_list.empty?
      channel.send_embed do |embed|
        embed.color = 0x3b88c3
        embed.title = "ℹ️ 接続中のチャンネルはありません"
      end
      return
    end

    channel.send_embed do |embed|
      embed.color = 0x3b88c3
      embed.title = "ℹ️ 接続中のチャンネル一覧"
      embed.description = "↔️ 相互接続　➡️ 一方向接続(送信側)　⬅️ 一方向接続(受信側)\n"
      link_list.each do |p_channel_id, item|
        embed.description += "\n#{LINK_MODE_ICONS[item[:mode]]} #{item[:name]} ID: `#{p_channel_id}`"
      end
    end
  end

  #================================================

  # 権限の検証
  def test_permittion(channel)
    bot_member = channel.server.member(@bot.profile.id)

    channel.send_embed do |embed|
      embed.color = 0x3b88c3
      embed.title = "ℹ️ BOTに必要な権限一覧"
      embed.description = ""
      REQUIRE_PERMIT.each do |action, summary|
        embed.description += bot_member.permission?(action, channel) ? "✅" : "⚠️"
        embed.description += " #{summary}\n"
      end
    end
  end

  #================================================

  # 相手チャンネル表示取得
  def gen_channel_disp(channel, p_channel)
    if channel.server == p_channel.server
      return "#{p_channel.mention}"
    end
    "#{p_channel.server.name} ##{p_channel.name}"
  end

  # Webhookのユーザー名生成
  def gen_webhook_username(channel, p_channel, user)
    server_name = channel.server != p_channel.server ? "#{channel.server.name} " : ""
    "#{user.distinct} (#{server_name}##{channel.name})"
  end
end
