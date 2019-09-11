/*
 Copyright (c) 2017 Mastercard
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import UIKit
import MPGSDK

class ProcessPaymentViewController: UIViewController {
    // MARK: - Properties
    var transaction: Transaction = Transaction()

    // the object used to communicate with the merchant's api
    var merchantAPI: MerchantAPI!
    // the ojbect used to communicate with the gateway
    var gateway: Gateway!
    
    // MARK: View Outlets
    @IBOutlet weak var createSessionStatusImageView: UIImageView!
    @IBOutlet weak var createSessionActivityIndicator: UIActivityIndicatorView!
    
    @IBOutlet weak var collectCardStatusImageView: UIImageView!
    @IBOutlet weak var collectCardActivityIndicator: UIActivityIndicatorView!
    
    @IBOutlet weak var updateSessionStatusImageView: UIImageView!
    @IBOutlet weak var updateSessionActivityIndicator: UIActivityIndicatorView!
    
    @IBOutlet weak var processPaymentStatusImageView: UIImageView!
    @IBOutlet weak var processPaymentActivityIndicator: UIActivityIndicatorView!
    
    @IBOutlet weak var paymentStatusView: UIView?
    @IBOutlet weak var paymentStatusIconView: UIImageView?
    @IBOutlet weak var statusTitleLabel: UILabel?
    @IBOutlet weak var statusDescriptionLabel: UILabel?
    
    @IBOutlet weak var continueButton: UIButton!
    
    // The next action to be executed when tapping the continue button
    var currentAction: (() -> Void)?
    
    // MARK: - View Controller Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        reset()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    // resets the payment view controller to a clean state prior to running a transaction
    func reset() {
        createSessionStatusImageView.isHidden = true
        createSessionActivityIndicator.stopAnimating()
        collectCardStatusImageView.isHidden = true
        collectCardActivityIndicator.stopAnimating()
        updateSessionStatusImageView.isHidden = true
        updateSessionActivityIndicator.stopAnimating()
        processPaymentStatusImageView.isHidden = true
        processPaymentActivityIndicator.stopAnimating()
        
        paymentStatusView?.isHidden = true
        statusTitleLabel?.text = nil
        statusDescriptionLabel?.text = nil
        
        setAction(action: createSession, title: "Pay \(transaction.amountFormatted)")
    }
    
    func finish() {
        self.navigationController?.popViewController(animated: true)
    }
    
    /// Called to configure the view controller with the gateway and merchant service information.
    func configure(merchantId: String, region: GatewayRegion, merchantServiceURL: URL, applePayMerchantIdentifier: String?) {
        gateway = Gateway(region: region, merchantId: merchantId)
        merchantAPI = MerchantAPI(url: merchantServiceURL)
        transaction.applePayMerchantIdentifier = applePayMerchantIdentifier
    }
    
    
    @IBAction func continueAction(sender: Any) {
        currentAction?()
    }
    
    
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // if the view being presented is the card collection view, wait register the callbacks for when card information is collected or cancelled
        if let nav = segue.destination as? UINavigationController, let cardVC = nav.viewControllers.first as? CollectCardInfoViewViewController {
            cardVC.viewModel.transaction = transaction
            cardVC.completion = cardInfoCollected
            cardVC.cancelled = cardInfoCancelled
        }
    }
 
}

// MARK: - 1. Create Session
extension ProcessPaymentViewController {
    /// This function creates a new session using the merchant service
    func createSession() {
        // update the UI
        createSessionActivityIndicator.startAnimating()
        continueButton.isEnabled = false
        continueButton.backgroundColor = .lightGray
        
        merchantAPI.createSession { (result) in
            DispatchQueue.main.async {
                // stop the activity indictor
                self.createSessionActivityIndicator.stopAnimating()
                guard case .success(let response) = result,
                    "SUCCESS" == response[at: "gatewayResponse.result"] as? String,
                    let session = response[at: "gatewayResponse.session.id"] as? String,
                    let apiVersion = response[at: "apiVersion"] as? String else {
                        // if anything was missing, flag the step as having errored
                        self.stepErrored(message: "Error Creating Session", stepStatusImageView: self.createSessionStatusImageView)
                        return
                }
                
                // The session was created successfully
                self.transaction.session = GatewaySession(id: session, apiVersion: apiVersion)
                self.stepCompleted(stepStatusImageView: self.createSessionStatusImageView)
                self.collectCardInfo()
            }
        }
    }
}

// MARK: - 2. Collect Card Info
extension ProcessPaymentViewController {
    // Presents the card collection UI and waits for a response
    func collectCardInfo() {
        // update the UI
        collectCardActivityIndicator.startAnimating()
        
        performSegue(withIdentifier: "collectCardInfo", sender: nil)
    }
    
    func cardInfoCollected(transaction: Transaction) {
        // populate the card information
        self.transaction = transaction
        // mark the step as completed
        stepCompleted(stepStatusImageView: collectCardStatusImageView)
        collectCardActivityIndicator.stopAnimating()
        // start the action to update the session with payer data
        self.updateWithPayerData()
    }
    
    func cardInfoCancelled() {
        collectCardActivityIndicator.stopAnimating()
        self.stepErrored(message: "Card Information Not Entered", stepStatusImageView: self.collectCardStatusImageView)
    }
}

// MARK: - 3. Update Session With Payer Data
extension ProcessPaymentViewController {
    // Updates the gateway session with payer data using the gateway.updateSession function
    func updateWithPayerData() {
        // update the UI
        updateSessionActivityIndicator.startAnimating()
    
        guard let sessionId = transaction.session?.id, let apiVersion = transaction.session?.apiVersion else { return }
        
        // construct the Gateway Map with the desired parameters.
        var request = GatewayMap()
        request[at: "sourceOfFunds.provided.card.nameOnCard"] = transaction.nameOnCard
        request[at: "sourceOfFunds.provided.card.number"] = transaction.cardNumber
        request[at: "sourceOfFunds.provided.card.securityCode"] = transaction.cvv
        request[at: "sourceOfFunds.provided.card.expiry.month"] = transaction.expiryMM
        request[at: "sourceOfFunds.provided.card.expiry.year"] = transaction.expiryYY
        
        // if the transaction has an Apple Pay Token, populate that into the map
        if let tokenData = transaction.applePayPayment?.token.paymentData, let token = String(data: tokenData, encoding: .utf8) {
            request[at: "sourceOfFunds.provided.card.devicePayment.paymentToken"] = token
        }
        
        // execute the update
        gateway.updateSession(sessionId, apiVersion: apiVersion, payload: request, completion: updateSessionHandler(_:))
    }
    
    // Call the gateway to update the session.
    fileprivate func updateSessionHandler(_ result: GatewayResult<GatewayMap>) {
        DispatchQueue.main.async {
            self.updateSessionActivityIndicator.stopAnimating()
            
            guard case .success(_) = result else {
                self.stepErrored(message: "Error Updating Session", stepStatusImageView: self.updateSessionStatusImageView)
                return
            }
            
            // mark the step as completed
            self.stepCompleted(stepStatusImageView: self.updateSessionStatusImageView)

            self.prepareForProcessPayment()
        }
    }

    func prepareForProcessPayment() {
            statusTitleLabel?.text = "Confirm Payment Details"
            if transaction.isApplePay {
                statusDescriptionLabel?.text = "Apple Pay\n\(transaction.amountFormatted)"
            } else {
                statusDescriptionLabel?.text = "\(transaction.maskedCardNumber!)\n\(transaction.amountFormatted)"
            }
            setAction(action: processPayment, title: "Confirm and Pay")
    }
}

// MARK: - 5. Process Payment
extension ProcessPaymentViewController {
    /// Processes the payment by completing the session with the gateway.
    func processPayment() {
        // update the UI
        processPaymentActivityIndicator.startAnimating()
        continueButton.isEnabled = false
        continueButton.backgroundColor = .lightGray
        
        merchantAPI.completeSession(transaction: transaction) { (result) in
            DispatchQueue.main.async {
                self.processPaymentHandler(result: result)
            }
        }
    }
    
    func processPaymentHandler(result: Result<GatewayMap>) {
        processPaymentActivityIndicator.stopAnimating()
        guard case .success(let response) = result, "SUCCESS" == response[at: "gatewayResponse.result"] as? String else {
                stepErrored(message: "Unable to complete Pay Operation", stepStatusImageView: processPaymentStatusImageView)
                return
        }
        
        stepCompleted(stepStatusImageView: processPaymentStatusImageView)
        
        paymentStatusView?.isHidden = false
        paymentStatusIconView?.image = #imageLiteral(resourceName: "check")
        statusTitleLabel?.text = "Payment Successful!"
        statusDescriptionLabel?.text = nil
        
        setAction(action: finish, title: "Done")
    }
}

// MARK: - Helpers
extension ProcessPaymentViewController {
    fileprivate func stepErrored(message: String, detail: String? = nil, stepStatusImageView: UIImageView) {
        stepStatusImageView.image = #imageLiteral(resourceName: "error")
        stepStatusImageView.isHidden = false
        
        paymentStatusView?.isHidden = false
        paymentStatusIconView?.image = #imageLiteral(resourceName: "error")
        statusTitleLabel?.text = message
        statusDescriptionLabel?.text = detail
        
        setAction(action: self.finish, title: "Done")
    }
    
    fileprivate func stepCompleted(stepStatusImageView: UIImageView) {
        stepStatusImageView.image = #imageLiteral(resourceName: "check")
        stepStatusImageView.isHidden = false
    }
    
    fileprivate func setAction(action: @escaping (() -> Void), title: String) {
        continueButton.setTitle(title, for: .normal)
        currentAction = action
        continueButton.isEnabled = true
        continueButton.backgroundColor = brandColor
    }
    
    fileprivate func randomID() -> String {
        return String(UUID().uuidString.split(separator: "-").first!)
    }
}
