# 图片和提及

![架构图](https://example.com/diagram.png "架构")

![已上传](img_v3_uploaded-example)

![本地图片](../private/photo.png)

![引用图片][picture]

[picture]: https://example.com/reference.png

正文标签应可见：<at user_id="all">所有人</at>、<at user_id="ou_other">他人</at>。

Slack 标识只是文本：<@U123ABC>、<#C123ABC>、<!channel>、@all。

`![内联代码](https://example.com/code.png)` 与 `\*literal\*`。

```markdown
![代码内图片](https://example.com/code.png)
<at user_id="all">代码内标签</at>
```
