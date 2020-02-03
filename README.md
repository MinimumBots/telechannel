# Telechannel
このBOTは簡単なコマンド操作でチャンネル間の相互チャットや、一方のチャンネルへのメッセージ転送などを実現できるDiscord向けのBOTです。  
コマンドを実行するメンバーには**チャンネル管理**権限が必要になります。  

## できること
- 接続先チャンネルとのメッセージ交換
- 接続先チャンネルからのメッセージ転送
- 接続先チャンネルへのメッセージ転送
- 添付ファイルの送信
- 複数のチャンネルとの接続

## できないこと
- 接続先に送信されたメッセージの編集・削除
- WebhookやBOTのメッセージを接続先へ送信

## 使い方
**●指定チャンネルと接続**  
```/connect [チャンネルID or チャンネルメンション]```  
指定されたチャンネルID、またはチャンネルメンションのチャンネルと接続します。  
接続方法を、相互接続・一方向接続(受信側/送信側)から選択できます。  
  
**●指定チャンネルと切断**  
```/disconnect [チャンネルID or チャンネルメンション]```  
指定されたチャンネルID、またはチャンネルメンションのチャンネルから切断します。  
  
**●接続中チャンネル一覧**  
```/connecting```  
このチャンネルと接続してるチャンネルの接続方法と名前、IDを表示します。  
  
**●権限の検証**  
```/connectable```  
このチャンネルでBOTの動作に必要な権限があるか、検証します。  

## 注意点
接続毎にWebhookを生成します。  
すべてのメッセージを送信する保証はできません。  

## 導入方法
次のリンクからご自身のサーバーに導入できます。  
https://discordapp.com/api/oauth2/authorize?client_id=653253608858583040&permissions=536964160&scope=bot  
