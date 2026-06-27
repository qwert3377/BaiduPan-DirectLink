// 在 NSObject (BaiduPanTroll) 的 @implementation 里添加这个方法：
- (void)bdt_copyLinkTapped:(id)sender {
    NSString *link = objc_getAssociatedObject(sender, "linkText");
    if (link) {
        copyToClipboard(link);
        showToast(@"直链已复制到剪贴板！");
    }
}

// 替换原 showLinkDialog 函数为下面这个：
static void showLinkDialog(NSString *link, NSString *fileName, NSString *fileId, NSString *pdfPath) {
    // 1. 用 UIViewController 作为 contentViewController，避免 KVC 布局冲突
    UIViewController *contentVC = [[UIViewController alloc] init];
    contentVC.preferredContentSize = CGSizeMake(270, 160);
    
    UIView *container = contentVC.view;
    container.backgroundColor = [UIColor clearColor];
    
    // 文件名
    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 270, 20)];
    nameLabel.text = [NSString stringWithFormat:@"%@ 的直链已成功复制到剪贴板。", fileName];
    nameLabel.font = [UIFont systemFontOfSize:13];
    nameLabel.textColor = [UIColor darkTextColor];
    nameLabel.numberOfLines = 0;
    [nameLabel sizeToFit];
    CGRect nameFrame = nameLabel.frame;
    nameFrame.size.width = 270;
    nameLabel.frame = nameFrame;
    [container addSubview:nameLabel];
    
    CGFloat nameH = nameLabel.frame.size.height + 8;
    
    // 2. 用 UIScrollView 水平包裹长链接，避免撑爆布局
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, nameH, 200, 36)];
    scrollView.showsHorizontalScrollIndicator = YES;
    scrollView.layer.borderColor = [UIColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0].CGColor;
    scrollView.layer.borderWidth = 1.0;
    scrollView.layer.cornerRadius = 6;
    scrollView.backgroundColor = [UIColor colorWithRed:0.97 green:0.97 blue:1.0 alpha:1.0];
    
    UILabel *linkLabel = [[UILabel alloc] init];
    linkLabel.text = link;
    linkLabel.font = [UIFont fontWithName:@"Menlo" size:11];
    linkLabel.textColor = [UIColor colorWithRed:0.18 green:0.42 blue:1.0 alpha:1.0];
    [linkLabel sizeToFit];
    linkLabel.frame = CGRectMake(8, 8, linkLabel.frame.size.width, 20);
    scrollView.contentSize = CGSizeMake(linkLabel.frame.size.width + 16, 36);
    [scrollView addSubview:linkLabel];
    [container addSubview:scrollView];
    
    // 再次复制按钮
    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(210, nameH, 60, 36);
    [copyBtn setTitle:@"再次复制" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.42 blue:1.0 alpha:1.0];
    copyBtn.layer.cornerRadius = 6;
    copyBtn.layer.masksToBounds = YES;
    [copyBtn addTarget:nil action:@selector(bdt_copyLinkTapped:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(copyBtn, "linkText", link, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [container addSubview:copyBtn];
    
    CGFloat hintY = nameH + 44;
    UILabel *hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, hintY, 270, 20)];
    hintLabel.text = @"提示：可使用 IDM、Aria2、Motrix 等工具粘贴下载";
    hintLabel.font = [UIFont systemFontOfSize:12];
    hintLabel.textColor = [UIColor grayColor];
    [container addSubview:hintLabel];
    
    // 3. 移除 UITextField，改用 UILabel，杜绝键盘焦点竞争
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"直链已复制"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert setValue:contentVC forKey:@"contentViewController"];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"已复制，恢复原名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
            DLog(@"Restore: %@", ok ? @"OK" : e.localizedDescription);
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保持pdf后缀" style:UIAlertActionStyleCancel handler:nil]];
    
    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}
