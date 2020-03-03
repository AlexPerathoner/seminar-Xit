import XCTest

/// Tests that change the repository, and must therefore get a fresh copy of
/// the test repo for each run.
class ModifyingUITests: XCTestCase
{
  var env: TestRepoEnvironment!

  override func setUp()
  {
    guard let env = TestRepoEnvironment(.testApp)
    else {
      XCTFail("Environment setup failed")
      return
    }
    
    self.env = env
  }
  
  func testRenameBranch()
  {
    env.open()
    
    let oldBranchName = "and-how"
    let newBranchName = "and-then"

    Sidebar.list.staticTexts[oldBranchName].rightClick()
    XitApp.menuItems["Rename"].click()
    XitApp.typeText("\(newBranchName)\r")
    XCTAssertTrue(Sidebar.list.staticTexts[newBranchName].exists)

    let branches = env.git.branches()
    
    XCTAssertFalse(branches.contains(oldBranchName))
    XCTAssertTrue(branches.contains(newBranchName))
  }
  
  func testTitleBarBranchSwitch()
  {
    env.open()
    
    let otherBranch = "feature"
    
    Window.branchPopup.click()
    XitApp.menuItems[otherBranch].click()
    XCTAssertEqual(Window.branchPopup.value as? String, otherBranch)
    
    let currentBranch = env.git.currentBranch()
    
    XCTAssertEqual(currentBranch, otherBranch)
  }
  
  func testFilterBranchFolder()
  {
    let folderName = "folder"
    let subBranchName = "and-why"
    
    _ = env.git.run(args: ["branch", "\(folderName)/\(subBranchName)"])
    env.open()
    
    let newBranchCell = Sidebar.cell(named: "new")

    XCTAssertTrue(newBranchCell.exists)
    
    Sidebar.filter.click()
    Sidebar.filter.typeText("a")
    wait(for: [absence(of: newBranchCell)], timeout: 5.0)

    // Expand the folder
    Sidebar.list.children(matching: .outlineRow).element(boundBy: 9)
           .disclosureTriangles.firstMatch.click()

    let folderCell = Sidebar.cell(named: folderName)
    let subBranchCell = Sidebar.cell(named: subBranchName)
    
    XCTAssertTrue(folderCell.exists)
    XCTAssertTrue(subBranchCell.waitForExistence(timeout: 1.0))

    Sidebar.filter.typeText("s")
    
    wait(for: [absence(of: folderCell)], timeout: 5.0)
    XCTAssertFalse(subBranchCell.exists)
  }
  
  func reset(modeButton: XCUIElement)
  {
    // change a file
    // change another file and stage it
    HistoryList.row(1).rightClick()
    HistoryList.ContextMenu.resetItem.click()
    XCTAssertTrue(ResetSheet.window.waitForExistence(timeout: 0.5))
    modeButton.click()
    ResetSheet.resetButton.click()
  }
  
  func testResetSoft()
  {
    env.open()
    
    reset(modeButton: ResetSheet.softButton)
    Sidebar.stagingCell.click()

    StagedFileList.assertFiles(["README.md", "hero_slide1.png", "jquery-1.8.1.min.js"])
    WorkspaceFileList.assertFiles(["UntrackedImage.png"])
  }
  
  func testResetMixed()
  {
    env.open()
    
    reset(modeButton: ResetSheet.mixedButton)

    // verify the reset state: index is clean, workspace is not
  }
  
  func testResetHard()
  {
    env.open()
    
    reset(modeButton: ResetSheet.hardButton)
    Sidebar.stagingCell.click()

    StagedFileList.assertFiles([])
    // Untracked files survive a hard reset
    WorkspaceFileList.assertFiles(["UntrackedImage.png"])
  }
}
