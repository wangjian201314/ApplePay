//
//  ApplePayManager.swift
//  ChatGPTDemo
//
//  Created by jian on 2023/5/25.
//

import Foundation
import RxSwift
import StoreKit
import SVProgressHUD
import TPInAppReceipt

class ApplePayManager: NSObject {
    enum PayFailedType {
        case notProduct
        case restored
        case cancel
        case failed
    }

    enum PaySuccessType {
        case requestProduct
        case purchase
        case restore
    }

    typealias Success = (PaySuccessType) -> Void
    typealias Failed = (PayFailedType) -> Void

    static let shared = ApplePayManager()

    private let bag = DisposeBag()
    private var successBlock: Success?
    private var failedBlock: Failed?
    private var newVipList: [VIPModel] = []
    private var sKProductList: [SKProduct] = []

    func observer() {
        SKPaymentQueue.default().add(self)
    }

    // 恢复购买
    func restorePurchases(success: @escaping Success) {
        SKPaymentQueue.default().restoreCompletedTransactions()
    }

    func requestProductList(vipList: [VIPModel], success: @escaping Success, failed: @escaping Failed) {
        successBlock = success
        failedBlock = failed
        newVipList = vipList
        var productIdList: Set<String> = []
        for model in vipList {
            productIdList.insert(model.productId)
        }

        if SKPaymentQueue.canMakePayments() {
            let request = SKProductsRequest(productIdentifiers: productIdList)
            request.delegate = self
            request.start()
        }
    }

    func applePay(productId: String, success: @escaping Success) {
        for product in sKProductList where product.productIdentifier == productId {
            let payment = SKMutablePayment(product: product)
            SKPaymentQueue.default().add(payment)
        }
    }
}

extension ApplePayManager {
    private func verifyPurchase(transactionIdentifier: String, appStoreReceiptURL: String, transaction: SKPaymentTransaction) {
        let parameters = ["receipt_data": appStoreReceiptURL,
                          "transaction_identifier": transactionIdentifier]
        PayService.default.applePayVerify(parameters: parameters).subscribe { [weak self] response in
            DispatchQueue.main.async {
                SVProgressHUD.dismiss()
                guard let self = self else { return }
                if let response = response, response.code == 200, response.status == 1 {
                    SVProgressHUD.showSuccess(withStatus: "Purchase success".gys.localized)
                    self.successBlock?(.purchase)
                } else {
                    SVProgressHUD.showError(withStatus: "Purchase failure".gys.localized)
                }
                // 注销交易
                SKPaymentQueue.default().finishTransaction(transaction)
                LoadManager.share.requestVipList()
                LoadManager.share.requestUserInfo()
            }
        } onFailure: { _ in
            SVProgressHUD.dismiss()
        } onDisposed: { }.disposed(by: bag)
    }

    private func verifyRestore(appStoreReceiptURL: String, transaction: SKPaymentTransaction) {
        let parameters = ["receipt_data": appStoreReceiptURL]
        PayService.default.appleRestore(parameters: parameters).subscribe { response in
            DispatchQueue.main.async {
                SVProgressHUD.dismiss()
                if let response = response, response.code == 200 {
                    SVProgressHUD.showSuccess(withStatus: "Restore success".gys.localized)
                    self.successBlock?(.restore)
                } else {
                    SVProgressHUD.showError(withStatus: "Restore failure".gys.localized)
                }
                // 注销交易
                SKPaymentQueue.default().finishTransaction(transaction)
                LoadManager.share.requestVipList()
                LoadManager.share.requestUserInfo()
            }
        } onFailure: { _ in
            SVProgressHUD.dismiss()
        } onDisposed: { }.disposed(by: bag)
    }

    private func response(transaction: SKPaymentTransaction, isRestore: Bool) {
        guard let receiptUrl = Bundle.main.appStoreReceiptURL,
              let transactionIdentifier = transaction.transactionIdentifier else {
            if isRestore {
                DispatchQueue.main.async {
                    SVProgressHUD.showError(withStatus: "暂无购买数据")
                }
            }
            return
        }

        let data = NSData(contentsOf: receiptUrl)
        if let appStoreReceiptURL = data?.base64EncodedString(options: .endLineWithLineFeed) {
            DispatchQueue.main.async {
                SVProgressHUD.show()
            }

            // 服务器验证
            if isRestore {
                verifyRestore(appStoreReceiptURL: appStoreReceiptURL, transaction: transaction)
            } else {
                verifyPurchase(transactionIdentifier: transactionIdentifier, appStoreReceiptURL: appStoreReceiptURL, transaction: transaction)
            }
        }
    }
}

extension ApplePayManager {
    private func decimalNumber(price: String, vipDays: String, days: String) -> String {
        if Int(vipDays) ?? 0 <= 0 || vipDays.isEmpty || price.isEmpty || days.isEmpty {
            return ""
        }

//        debugPrint("price==\(price),vipDays==\(vipDays),days==\(days)")
        let decimalNumber1 = NSDecimalNumber(string: price)
        let decimalNumber2 = NSDecimalNumber(string: vipDays)
        let decimalNumber3 = NSDecimalNumber(string: days)
        var dividing = decimalNumber1.dividing(by: decimalNumber2)
        dividing = dividing.multiplying(by: decimalNumber3)
        return dividing.gys.toString()
    }
}

extension ApplePayManager: SKProductsRequestDelegate, SKPaymentTransactionObserver {
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        if response.products.count == 0 {
            failedBlock?(.notProduct)
            return
        }

        sKProductList = response.products
        for product in response.products {
            for model in newVipList where product.productIdentifier == model.productId {
                let currencySymbol = product.priceLocale.currencySymbol ?? ""
                let weekPrice = decimalNumber(price: model.price, vipDays: String(model.vipDays), days: "7")
                model.price = product.price.gys.toString()
                model.currencySymbol = currencySymbol
                model.weekPrice = weekPrice
                model.productName = product.localizedTitle
                model.isFree = product.introductoryPrice != nil ? true : false
            }
        }

        UserDefaultsCore.set(value: newVipList, for: vipListUserInfo)
        successBlock?(.requestProduct)
    }

    /// SKPaymentTransactionObserver购买回调
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for trans in transactions {
            switch trans.transactionState {
            case .purchased:
                response(transaction: trans, isRestore: false)
                if trans.original != nil {
                    debugPrint("自动订阅购买成功")
                } else {
                    debugPrint("第一次购买成功")
                }
            case .purchasing:
                debugPrint("商品添加进列表")
            case .restored:
                debugPrint("恢复购买")
                SKPaymentQueue.default().finishTransaction(trans)
            case .failed:
                debugPrint("购买失败")
                SKPaymentQueue.default().finishTransaction(trans)
            default:
                break
            }
        }
    }

    func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
        DispatchQueue.main.async {
            SVProgressHUD.showSuccess(withStatus: "Restore failure".gys.localized)
        }
        // 移除监听
//        SKPaymentQueue.default().remove(self)
        debugPrint("系统恢复购买失败 \(error)")
    }

    func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        debugPrint("系统恢复购买成功")
        for transaction in queue.transactions where transaction.transactionState == .restored {
            response(transaction: transaction, isRestore: true)
        }
    }

    /// 支付错误
    func request(_ request: SKRequest, didFailWithError error: Error) {
        debugPrint(error)
    }

    /// 结束请求
    func requestDidFinish(_ request: SKRequest) {
        debugPrint("支付结束了")
        do {
            let receipt = try InAppReceipt.localReceipt()
            for model in newVipList {
                let isEligible = receipt.isEligibleForIntroductoryOffer(for: model.productId)
                model.isEligible = isEligible
                debugPrint("免费资格==\(isEligible)")
            }
            debugPrint("")

        } catch {
            debugPrint("\(error)")
        }
    }
}
